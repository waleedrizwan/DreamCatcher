I have verified the key API facts. One important finding from research: there is a reported issue of the built-in SoundAnalysis classifier failing in the background on some iOS versions, which materially affects the architecture — I have designed around it with a spike plus fallback plan. Here is the iOS design document.

---

# Dream Catcher — iOS App Design Document

Greenfield native iOS app. Swift + SwiftUI. Local-only data, on-device ML snore detection, overnight recording sessions with morning reports, clip playback, and history/trends.

## 0. Top-line risk callout (read first)

The plan assumes `SoundAnalysis` (`SNClassifySoundRequest` with the built-in `.version1` classifier, which includes a `"snoring"` label) runs all night while the screen is locked, under `UIBackgroundModes: audio`. Audio *capture* in the background with that entitlement is well-established and reliable. However, an Apple Developer Forums report (thread 811582) describes the built-in classifier itself failing with `SNErrorCode.operationFailed` (code 2) once the app is backgrounded/screen-locked on iOS 17.x, while mic capture continues fine, and resuming instantly on foreground. It is a single unanswered thread, so it may be configuration- or version-specific — but it strikes exactly our core use case.

**Mitigation is baked into this design:**
- **Spike 0 (first task of the project):** a 20-line prototype that runs `AVAudioEngine` + `SNAudioStreamAnalyzer` with the screen locked for 60+ minutes on physical devices at our min iOS and latest iOS. Go/no-go on the built-in classifier.
- **Fallback A (product-level):** "Screen-on nightstand mode" — `UIApplication.shared.isIdleTimerDisabled = true` with a near-black UI. The stated use case has the phone charging on a nightstand, so this is acceptable as a stopgap (several shipping snore apps work this way).
- **Fallback B (technical, preferred long-term):** bundle our own Core ML sound classifier (Create ML "Sound Classifier" trained on AudioSet/ESC-50 snoring data, or YAMNet converted to Core ML) and run it via `MLModel.prediction` directly on 0.975 s / 15,600-sample @ 16 kHz frames with `MLModelConfiguration.computeUnits = .cpuOnly` (ANE access can be deprioritized in background). This bypasses SoundAnalysis entirely and — bonus — uses the same input framing as YAMNet on Android, so the two platforms could share thresholds and the behavior spec exactly.

The detection pipeline below is deliberately structured so the classifier is a swappable `SnoreClassifying` protocol implementation; a failed spike changes one file, not the architecture.

## 1. Minimum iOS version: **iOS 17.0**

- `SNClassifySoundRequest(classifierIdentifier: .version1)` — the built-in classifier with the `"snoring"` label — requires iOS 15.0+. Confirmed: `.version1` is the only built-in classifier identifier, its label set (300+ classes) includes `snoring`, plus adjacent labels we can exploit (`breathing`, `cough`, `gasp`, `speech`; verified against the 303-label list on iOS 26 — there is no `snort`, no choking, no teeth-grinding label).
- Swift Charts requires iOS 16.0+ (and `chartScrollableAxes`/scrolling charts, useful for the night timeline, is iOS 17+).
- The Observation framework (`@Observable`) requires iOS 17.0+ and is the recommended SwiftUI state pattern; it removes the `ObservableObject`/`@Published` boilerplate and over-invalidation.
- As of mid-2026, iOS 17 covers the overwhelming majority of active iPhones; nothing about this app targets old hardware.
- We do **not** need iOS 18/26-only APIs. SwiftData would push no version constraint beyond 17 but we are choosing GRDB anyway (section 5).

Deployment target: `IPHONEOS_DEPLOYMENT_TARGET = 17.0`. iPhone-only (`TARGETED_DEVICE_FAMILY = 1`); iPad support is trivial later but the nightstand use case is phone-first.

## 2. Background overnight recording

### 2.1 Audio session configuration

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord,
                        mode: .measurement,
                        options: [.mixWithOthers, .allowBluetoothA2DP]) // A2DP = BT *output* ok, never BT *input*
try session.setActive(true)
// Force the built-in mic; never record through AirPods sitting in their case:
if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
    try session.setPreferredInput(builtIn)
}
try session.setPreferredSampleRate(48_000)
try session.setPreferredIOBufferDuration(0.1) // larger buffers = fewer wakeups = better battery
```

- **Category `.playAndRecord`**, not `.record`: lets the morning flow play clips and lets us play a brief "session started" confirmation without category churn; also more forgiving with other audio (user's podcast/white-noise app) via `.mixWithOthers`.
- **Mode `.measurement`** disables system input processing (AGC, EQ). We need stable, comparable RMS levels across the night for the light/moderate/loud intensity buckets; AGC would silently re-gain quiet rooms and wreck the calibration. Trade-off: slightly less "enhanced" far-field pickup — acceptable at nightstand distance (0.5–1.5 m).
- `.mixWithOthers` means starting our session does not kill the user's sleep sounds app; it also reduces the chance *their* audio interrupts *us*.

### 2.2 Info.plist / capability

- `UIBackgroundModes` = `["audio"]`. With an active audio session that has *running input*, the app is not suspended when the screen locks — this is the standard, App-Review-accepted mechanism for recorder apps. The session must be started while the app is foregrounded; after that, lock away.
- What the user sees when locked: the mic-in-use indicator (orange dot / Dynamic Island pill). Expected; mention it in onboarding so it isn't alarming.

### 2.3 Interruptions (phone calls, Siri, alarms, other apps)

Subscribe to `AVAudioSession.interruptionNotification`:

- `.began`: stop the `AVAudioEngine`, mark an **interruption segment** in the session record (the timeline chart renders these as gray gaps — honest data beats invisible holes).
- `.ended`: if `AVAudioSessionInterruptionOptions` contains `.shouldResume`, reactivate the session and restart the engine immediately. If not, attempt reactivation anyway on a retry loop (1 s, 5 s, 15 s, 60 s backoff) — after a phone call ends, reactivation usually succeeds even without `.shouldResume`. **Critical caveat:** interruption-ended callbacks are not always delivered to backgrounded apps. Belt-and-suspenders: also retry on `UIApplication.didBecomeActiveNotification` and on a repeating check while any interruption is outstanding. If we stay dead >N minutes and get suspended, section 2.6 recovery applies.
- `AVAudioSession.mediaServicesWereResetNotification`: rare daemon crash; tear down and rebuild the entire engine + analyzer from scratch.

### 2.4 Route changes

`AVAudioSession.routeChangeNotification`:
- Reason `.oldDeviceUnavailable` / `.newDeviceAvailable` (AirPods opened, CarPlay, etc.): re-assert `setPreferredInput(builtInMic)`. Log a route-change marker on the timeline.
- `AVAudioEngineConfigurationChange` notification: the engine's input node format can change under us (sample rate/channel changes on route change) — restart the engine and reinstall the tap with the new format. This is the classic overnight-recorder crash; handle it from day one.

### 2.5 Screen lock, all-night liveness

- Engine started in foreground → user locks phone → app keeps running under the audio background mode. No timers, no `beginBackgroundTask` needed while input runs.
- **Never** fully deactivate the audio session mid-night except on explicit Stop. Any window where the engine is stopped and the session inactive is a window where iOS may suspend us.
- Watchdog: a 60 s repeating check (dispatch timer on our audio queue — it runs because the process runs) verifying `engine.isRunning`; if not, run the restart path.

### 2.6 Crash/jetsam recovery

Persist incrementally (section 5): session row written at start, episodes and minute-aggregates written as they happen. On next launch, an open session with no `endedAt` is finalized as "ended unexpectedly at last-written minute" and still produces a (truncated) report. Never hold a night's data only in memory.

### 2.7 Battery expectations

Mic capture + one classifier inference every 0.75 s is light: expect roughly 3–6%/hour unplugged (measure in Spike 0 with Instruments Energy Log), i.e. an 8-hour night is survivable (~25–50%) but not comfortable. The product stance: **strongly recommend charging** (the stated use case already assumes it). Show a non-blocking warning at session start if `UIDevice.current.batteryState == .unplugged` and level < 50%. Battery savers: 0.1 s IO buffer, overlapFactor 0.5 (not 0.9), no UI updates while locked, no disk writes except on episode events and 1/minute aggregates.

## 3. Detection pipeline

```
AVAudioEngine.inputNode tap (native format, 48 kHz, buffer ~4800 frames)
   ├──> RingBuffer (raw PCM, last 20 s, for clip capture)           [audio thread, lock-free]
   └──> AVAudioConverter -> 16 kHz mono Float32
            ├──> LevelMeter: RMS dBFS + peak per window             [pure Swift, testable]
            └──> SnoreClassifier (protocol)
                  impl 1: SoundAnalysisClassifier
                     SNAudioStreamAnalyzer + SNClassifySoundRequest(.version1)
                     windowDuration = CMTime(seconds: 1.5, preferredTimescale: 16_000)
                     overlapFactor  = 0.5   // → one result every 0.75 s
                  impl 2 (fallback): CoreMLClassifier (0.975 s / 15,600-sample frames)
                        ↓ SNResultsObserving / delegate
            ClassificationFrame { time, snoreConfidence, otherTopLabel, rmsDBFS, peakDBFS }
                        ↓
            EpisodeAggregator (pure state machine, the heart of the app)
                        ↓
            SnoreEpisode { start, end, peakDBFS, meanConfidence, intensity }
                        ↓  events
            SessionRecorder: writes DB rows, triggers ClipWriter
```

### 3.1 Concrete settings to start with (tune in beta)

| Parameter | Initial value | Rationale |
|---|---|---|
| Analysis window | 1.5 s (Apple's live-classification sample size) | Snore inhale bursts are ~0.5–1.5 s |
| `overlapFactor` | 0.5 (hop 0.75 s) | 0.9 doubles+ inference count for little gain; battery |
| Loudness gate | skip/ignore windows with RMS < **−55 dBFS** | Below quiet-room noise floor; kills false positives from silence |
| Snore-positive window | `snoring` confidence ≥ **0.6** AND gate passed | Start permissive; precision recovered by the aggregator |
| Episode start | **2 consecutive** positive windows (~1.5 s) | Debounce one-off blips |
| Episode end | **20 s** with no positive window | Snoring is periodic (breath cycle 3–6 s); must not end an episode between breaths |
| Episode merge | merge episodes with gap < **30 s** | Post-processing at session end |
| Minimum episode | discard episodes < **10 s** | Noise robustness |
| Intensity buckets (per-episode peak dBFS) | light < −38, moderate −38…−28, loud > −28 | Placeholder; calibrate on-device in beta; document that dBFS ≠ dB SPL and depends on distance |

Also read the classifier's competing labels: if `speech`/`television` confidence beats `snoring` in the same window, veto it — cheap protection against TV/partner-talking false positives.

### 3.2 Testability structure

- `LevelMeter`, `EpisodeAggregator`, and the ring buffer are **pure Swift with zero AVFoundation imports** — they take `[Float]` / value-type frames in and emit value-type events out. They live in a platform-agnostic SPM package (`SnoreCore`).
- `SnoreClassifying` protocol: `func process(_ buffer: AudioChunk) async -> [ClassificationFrame]`. `SoundAnalysisClassifier` and a `ScriptedClassifier` (returns a canned sequence, for tests and UI previews) both implement it.
- The `EpisodeAggregator` is a synchronous reducer: `mutating func consume(_ frame: ClassificationFrame) -> [AggregatorEvent]` — trivially unit-testable (section 8).

## 4. Clip capture (episodes only, never full-night audio)

- **Ring buffer:** last **20 s** of the converted 16 kHz mono Float32 stream ≈ 1.28 MB fixed allocation. Written on the audio path, read on episode events (single-producer/single-consumer, index-based, no locks on the hot path).
- On `episodeStarted`: snapshot the ring buffer to get **3 s of pre-roll**, open an `AVAudioFile` for writing with settings `[AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]` at `<clipURL>.m4a` (AVAudioFile encodes PCM→AAC internally), append pre-roll, then live-append until `episodeEnded` or the **per-clip cap of 30 s**, whichever first. If the episode continues past 30 s we keep counting duration but stop writing audio.
- **Per-night caps:** max **50 clips** and max **40 MB** per session (30 s @ 32 kbps ≈ 120 KB, so ~6 MB typical — the cap is a safety net). After the cap: keep episodes (metadata always recorded), skip audio. Prefer replacing the quietest saved clip if a new episode's peak is ≥ 6 dB louder ("keep the highlights" behavior).
- **File-protection gotcha:** files created while the device is locked must not use `NSFileProtectionComplete` (writes would fail). Keep the default `.completeUntilFirstUserAuthentication` for the clips directory and the database. Do not "harden" this later without re-testing overnight capture.
- Retention setting: auto-delete clip audio (not stats) after 30 days, user-adjustable.

## 5. Storage: **GRDB** (+ files on disk)

Recommendation: **GRDB.swift** over Core Data and SwiftData.
- SwiftData: too young for a write-heavy background audio pipeline; history of predicate/migration bugs; main-actor-flavored API is awkward from an audio callback context.
- Core Data: workable but heavy ceremony; its object-graph features buy nothing for a two-table schema.
- GRDB: plain SQL/SQLite (matches the Android/Room side almost 1:1 — helps the shared behavior spec), explicit `DatabaseQueue` serialization that is safe to call from our session actor while backgrounded, WAL mode, trivially testable with in-memory databases, first-class `ValueObservation` for driving SwiftUI.

Schema (v1):

```sql
CREATE TABLE session (
  id TEXT PRIMARY KEY,            -- UUID
  startedAt REAL NOT NULL,        -- unix epoch
  endedAt REAL,                   -- NULL = in progress / crashed
  endReason TEXT NOT NULL DEFAULT 'user', -- user | crashRecovered | interruptedTooLong
  totalSnoreSeconds REAL NOT NULL DEFAULT 0,
  episodeCount INTEGER NOT NULL DEFAULT 0,
  lightCount INTEGER NOT NULL DEFAULT 0,
  moderateCount INTEGER NOT NULL DEFAULT 0,
  loudCount INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE episode (
  id TEXT PRIMARY KEY,
  sessionId TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  startedAt REAL NOT NULL, endedAt REAL NOT NULL,
  peakDBFS REAL NOT NULL, meanConfidence REAL NOT NULL,
  intensity TEXT NOT NULL,        -- light | moderate | loud
  clipRelativePath TEXT           -- NULL if capped/failed
);
CREATE TABLE minuteAggregate (    -- powers the timeline chart without touching episodes
  sessionId TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  minuteIndex INTEGER NOT NULL,   -- minutes since session start
  snoreSeconds REAL NOT NULL, maxDBFS REAL,
  state TEXT NOT NULL,            -- quiet | snoring | interrupted
  PRIMARY KEY (sessionId, minuteIndex)
);
```

File layout:
```
Application Support/
  DreamCatcher.sqlite (+ -wal, -shm)
  Clips/<sessionId>/<episodeId>.m4a
```
Mark `Clips/` with `isExcludedFromBackup = true` (stats are small and back up; audio is bulky and privacy-sensitive). Store only relative paths in the DB (container path changes across restores).

## 6. App architecture (SwiftUI)

- Pattern: **SwiftUI + `@Observable` models + one actor for the session**. No third-party architecture framework.
  - `RecordingSessionActor` (an `actor`): owns AVAudioEngine, analyzer, aggregator, clip writer, DB writes. The single mutable authority during a night.
  - `@Observable` view models per screen (`HomeModel`, `ReportModel`, `HistoryModel`) reading via GRDB `ValueObservation`.
  - `AppDependencies` struct injected through the environment; every service behind a protocol (`Clock`, `DatabaseWriting`, `SnoreClassifying`, `AudioSessionControlling`) so previews/tests use fakes.
- Screens (TabView: Home, History, Settings; Report pushed/presented):
  1. **Home / Record** — big Start button; pre-flight checks (mic permission, disk space, battery/charging hint); while recording: dim near-black UI, elapsed time, live "quiet/snoring" pip, Stop (confirm-to-stop to prevent pocket taps).
  2. **Night Report** — auto-presented on Stop and reachable from History. Summary cards (total snore time, episode count, session duration, % of night), intensity breakdown, timeline, episode list with inline clip playback (`AVAudioPlayer`, category `.playback`), delete-clip affordance.
  3. **History** — list grouped by week + month calendar grid (custom SwiftUI grid, not Charts) with per-day dot colored by snore severity; week/month trend charts.
  4. **Settings** — sensitivity (maps to confidence threshold Low 0.50 / Med 0.35 / High 0.22 on the YAMNet scale, spec §1.1), clip retention, storage usage + "delete all data", disclaimer, about.
- **Swift Charts:**
  - Timeline: `Chart` of `minuteAggregate` rows → `RectangleMark(xStart:xEnd:)` bins colored by intensity via `.foregroundStyle(by:)`; gray marks for interruption segments; `chartXScale` over the full night; `chartScrollableAxes(.horizontal)` (iOS 17) for long nights on small screens.
  - Trends: `BarMark` (x: night, y: total snore minutes) with `RuleMark` for the period average; `chartXSelection` for tap-to-inspect; second toggleable series for episode count.

## 7. Permissions & App Store

- `NSMicrophoneUsageDescription`: "DreamCatcher records through the microphone only during a sleep session you start, to detect snoring and save short snore clips. Audio never leaves your device." Request permission just-in-time on first Start, preceded by a one-screen explainer (raises grant rate).
- Privacy nutrition label: **"Data Not Collected"** — truthful because nothing leaves the device (no accounts, no analytics SDKs in MVP — adding any analytics later changes this label; resist it).
- Privacy manifest `PrivacyInfo.xcprivacy` (required): no tracking, no collected data types; declare required-reason APIs we use — `UserDefaults` (CA92.1) and file-timestamp APIs (C617.1) at minimum.
- Health/medical positioning (App Review Guideline 5.1.3 territory): the app **describes sounds, it does not diagnose**. Never use "sleep apnea," "diagnosis," or "medical" in UI or App Store copy except in the disclaimer itself. Disclaimer ("Not a medical device. Not intended to diagnose, treat, or monitor any condition, including sleep apnea. If you have concerns about your sleep or breathing, consult a physician.") appears: (1) in onboarding (acknowledged once), (2) footer of every Night Report, (3) Settings, (4) App Store description. Category: Health & Fitness; rating 4+.

## 8. Project scaffolding & tests

```
dream-catcher/
  DreamCatcher.xcodeproj
  DreamCatcher/                      # app target (thin): DreamCatcherApp.swift, screens, resources,
                                 # Info.plist (UIBackgroundModes=audio), PrivacyInfo.xcprivacy
  Packages/
    SnoreCore/                   # SPM, no UIKit/AVFoundation: ClassificationFrame.swift,
                                 # EpisodeAggregator.swift, LevelMeter.swift, RingBuffer.swift,
                                 # IntensityGrader.swift, Models.swift
      Tests/SnoreCoreTests/
    SnoreAudio/                  # AVFoundation layer: AudioCaptureEngine.swift,
                                 # SoundAnalysisClassifier.swift, ClipWriter.swift,
                                 # AudioSessionCoordinator.swift, RecordingSessionActor.swift
      Tests/SnoreAudioTests/     # uses ScriptedClassifier + temp dirs; no mic needed
    SnoreStorage/                # GRDB: AppDatabase.swift, migrations, repositories
      Tests/SnoreStorageTests/   # in-memory DatabaseQueue
  DreamCatcherUITests/               # smoke only: launch, tab navigation
```

Representative unit test for the detection state machine (lives in `SnoreCoreTests`, runs in milliseconds, no audio hardware):

```swift
func testEpisodeSurvivesBreathGapsButClosesAfterQuiet() {
    var agg = EpisodeAggregator(config: .default)   // start=2 windows, end=20s, hop=0.75s
    var events: [AggregatorEvent] = []
    // 3 snore bursts separated by 4s breath gaps, then 25s of quiet
    events += agg.consume(frames: .snorePattern(bursts: 3, burstWindows: 2,
                                                gapSeconds: 4, confidence: 0.8, rms: -30))
    events += agg.consume(frames: .quiet(seconds: 25, rms: -60))
    let started = events.compactMap(\.episodeStarted)
    let ended   = events.compactMap(\.episodeEnded)
    XCTAssertEqual(started.count, 1, "breath gaps must not split an episode")
    XCTAssertEqual(ended.count, 1)
    XCTAssertEqual(ended[0].intensity, .moderate)   // peak -30 dBFS → moderate bucket
}
```

Other required tests: single-blip rejection (<2 windows → no episode), sub-10 s discard, 30 s-gap merge, RMS gate veto despite high confidence, intensity bucket edges, ring-buffer wraparound, crash-recovery finalization of an open session, DB migration round-trip.

## 9. Implementation order

1. **Spike 0:** background SoundAnalysis lock-screen soak test on device (go/no-go; picks classifier impl).
2. `SnoreCore` (aggregator, meter, ring buffer) + full unit tests — pure logic, no Xcode-app dependencies.
3. `SnoreStorage` (GRDB schema, repositories) + tests.
4. `SnoreAudio` capture path: engine, session coordinator, interruption/route handling, classifier impl, clip writer.
5. App shell: Home/record flow end-to-end (record → DB → basic report numbers).
6. Report + Swift Charts timeline; clip playback.
7. History + trends; Settings; onboarding + disclaimer; privacy manifest.
8. Overnight field testing (real bedrooms, chargers, phone calls at 3 a.m., alarm clocks), threshold calibration, Energy Log profiling.

Key risks recap: (1) background classification (mitigated, section 0); (2) false positives from partners/TV/fans (mitigated by gate + competing-label veto + tunable sensitivity; needs beta calibration); (3) interruption-resume reliability overnight (mitigated by retry loop + watchdog + interruption segments); (4) input-format changes from route churn (engine-restart handling); (5) intensity buckets are device/distance-relative — set expectations in UI copy.

Sources: [SNClassifySoundRequest — Apple](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest), [SNClassifierIdentifier — Apple](https://developer.apple.com/documentation/soundanalysis/snclassifieridentifier), [Classifying live audio with a built-in classifier — Apple](https://developer.apple.com/documentation/SoundAnalysis/classifying-live-audio-input-with-a-built-in-sound-classifier), [Built-in classifier label list incl. snoring (SoundML)](https://github.com/chrisladd/SoundML), [Sound Analysis to the Tune of 300 Sounds — Swiftjective-C](https://www.swiftjectivec.com/sound-analysis-framework-built-in-model/), [Background classification failure report — Apple Dev Forums 811582](https://developer.apple.com/forums/thread/811582), [UIBackgroundModes — Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes), [windowDuration/overlapFactor usage — createwithswift.com](https://www.createwithswift.com/identify-individual-sounds-in-a-live-audio-buffer/).

### Critical Files for Implementation
- Packages/SnoreCore/Sources/SnoreCore/EpisodeAggregator.swift
- Packages/SnoreAudio/Sources/SnoreAudio/RecordingSessionActor.swift
- Packages/SnoreAudio/Sources/SnoreAudio/SoundAnalysisClassifier.swift
- Packages/SnoreStorage/Sources/SnoreStorage/AppDatabase.swift
- DreamCatcher/Screens/ReportView.swift