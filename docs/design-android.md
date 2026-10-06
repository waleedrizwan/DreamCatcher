# Android App Design — "Dream Catcher"

Greenfield native Android app: Kotlin, Jetpack Compose, on-device YAMNet snore detection, local-only Room + file storage. Proposed root: `android/`. All facts about Android 14/15/16 FGS rules, MediaPipe packaging, Play deadlines, and Vico versions were verified via web search (sources at the end).

---

## 1. SDK levels & foreground-service strategy

**Recommendation: `minSdk 29`, `targetSdk 36`, `compileSdk 36`.**

- Google Play already requires new apps to target API 35, and from **Aug 31, 2026 new apps/updates must target Android 16 (API 36)** — since this app ships after that date, target 36 from day one.
- minSdk 29 (Android 10, ~95%+ of devices in 2026) buys us: `AudioRecord.registerAudioRecordingCallback` + `AudioRecordingConfiguration.isClientSilenced()` (API 29) for detecting mic takeover, formalized concurrent-capture rules, and no legacy external-storage code paths. Nothing in the MVP justifies supporting Android 8/9.

**Foreground service rules (Android 14+, verified):**

- Manifest: `<service android:name=".session.SnoreSessionService" android:foregroundServiceType="microphone" android:exported="false"/>` plus permissions `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MICROPHONE` (both normal/manifest-only), `RECORD_AUDIO`, `POST_NOTIFICATIONS`, `WAKE_LOCK`.
- At start: `ServiceCompat.startForeground(this, NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)`. Targeting 34+ the type is **mandatory** at `startForeground` time or you get `MissingForegroundServiceTypeException`.
- **While-in-use restriction:** a `microphone`-type FGS **cannot be started while the app is in the background**, and explicitly cannot be launched from `BOOT_COMPLETED` (Android 14+). This fits our UX — the user taps Start with the app foregrounded. Consequence: if the OS kills the service mid-night, a `START_STICKY` restart may land while the app is "background" and the mic will be unavailable. Design: wrap `startForeground`/`AudioRecord` startup in try/catch for `ForegroundServiceStartNotAllowedException`/`SecurityException`; on failure, mark the session `interrupted` in Room and post a plain notification ("Session ended early — tap for partial report"). Never crash-loop.
- **No FGS timeout applies to us:** the Android 15+ 6-hour `Service.onTimeout()` limit applies to `dataSync`/`mediaProcessing` types only; `microphone` FGS may run all night.
- **Doze:** Doze only engages when the device is unplugged + stationary + screen off. The nightstand-while-charging case never enters Doze. For the unplugged case, an FGS keeps the process alive but does not guarantee CPU: hold a **`PARTIAL_WAKE_LOCK`** (`PowerManager.newWakeLock(PARTIAL_WAKE_LOCK, "dreamcatcher:session")`, `setReferenceCounted(false)`, acquired in `onStartCommand`, released in `onDestroy` — no timeout, session-scoped). In practice the active audio-capture path also holds the audio HAL awake, but the explicit wake lock is the documented-safe pattern.
- **Do not** request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` in MVP (Play policy scrutiny; FGS + wake lock is sufficient on stock Android). Risk to document: aggressive OEM task killers (Xiaomi/Huawei/OnePlus) can still kill FGSs — ship a Settings help screen linking users to OEM-specific "don't optimize" toggles (dontkillmyapp.com patterns), and rely on the heartbeat/interrupted-session recovery below.
- The mic **privacy indicator (green dot)** shows all night on Android 12+. Mention it in onboarding so users don't panic.

## 2. Recording pipeline

**`AudioRecord`, not Oboe.** Oboe buys low latency for real-time audio apps; we need reliability, not latency. Config:

- 16,000 Hz, mono, `ENCODING_PCM_16BIT` — natively matches YAMNet input, no resampling.
- Audio source: `VOICE_RECOGNITION` by default; upgrade to `UNPROCESSED` when `AudioManager.getProperty(PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"`. Rationale: `DEFAULT`/`MIC` may apply AGC/noise-suppression which (a) can attenuate snoring and (b) destroys absolute-loudness calibration for the light/moderate/loud buckets.
- Buffer: `bufferSize = max(4 * AudioRecord.getMinBufferSize(...), 32_000 bytes /* 1 s */)`. Read loop on a dedicated thread (or `Dispatchers.IO` + `while(isActive)`) pulling **1,600-sample (100 ms) chunks** into a reused `ShortArray`.
- The read loop runs inside `SnoreSessionService` and fans out each 100 ms chunk to: (1) RMS/loudness gate, (2) the 10 s PCM ring buffer, (3) the window assembler for inference.

**Interruption handling.** Recording apps don't take audio focus; the concern is *mic sharing*: a phone call or Assistant grabs the mic and Android silently feeds us zeros. Register `AudioRecord.registerAudioRecordingCallback` and check `AudioRecordingConfiguration.isClientSilenced()` (API 29): on silenced → pause inference, mark a `gap` in the session (so the report can show "mic unavailable 02:13–02:19"); on unsilenced → resume. Also treat >2 s of pure digital silence as a silenced-mic heuristic fallback.

**Heartbeat/crash recovery.** Service updates `sessions.last_heartbeat_at` every 60 s. On app launch, any session in state `active` with a stale heartbeat is closed as `interrupted` with `ended_at = last_heartbeat_at`, and a partial report is generated.

**Battery expectation:** continuous 16 kHz mono capture + gated inference ≈ **2–4%/hour** unplugged screen-off on a mid-range 2024+ device (inference itself is ~5–15 ms per 0.975 s window and mostly skipped in a quiet room). Home screen should nudge "plug in your phone" — matches the stated use case.

## 3. Detection: MediaPipe AudioClassifier (YAMNet), clips mode, gated

**Recommendation: MediaPipe Tasks AudioClassifier** (`com.google.mediapipe:tasks-audio`, Maven Central, use latest release) with the official **`yamnet.tflite`** (~4 MB, bundled in assets) rather than raw TFLite/LiteRT interpreter. Rationale: it ships YAMNet with label metadata ("Snoring" is an AudioSet class), handles float conversion/score mapping, supports `categoryAllowlist`/`scoreThreshold`, and is Google-maintained under AI Edge. Raw LiteRT would save one dependency but re-implements label parsing for no MVP benefit. (Escape hatch: hide it behind a `SnoreClassifier` interface so a LiteRT impl can be swapped in.)

**Use `RunningMode.AUDIO_CLIPS`, not `AUDIO_STREAM`.** Stream mode wants a continuous feed, which defeats the loudness gate. With clips mode *we* own windowing:

- **Window assembler:** accumulate 16 kHz samples; emit a **15,600-sample (0.975 s) window every 7,800 samples (50% overlap ⇒ ~2 windows/sec)**.
- **Loudness gate (runs before inference):** per 100 ms chunk compute RMS dBFS. Maintain an adaptive noise floor (exponential moving 10th-percentile, seeded during the first 2 min). **Open the gate when RMS > max(floor + 6 dB, −60 dBFS)**; when closed, skip inference entirely (this is the battery win — a quiet bedroom runs near-zero inference). Keep updating the floor while closed.
- **Inference:** `AudioClassifier.createFromOptions(context, options)` with `BaseOptions.setModelAssetPath("yamnet.tflite")`, `setRunningMode(AUDIO_CLIPS)`, `setScoreThreshold(0.05f)`, `categoryAllowlist = ["Snoring", "Snort", "Breathing", "Speech"]` (Speech kept as a *negative* signal). Feed via `AudioData.create(AudioDataFormat(1 ch, 16000f), 15600)` + `audioData.load(floatWindow)` + `classifier.classify(audioData)`.
- **Window positive:** `score("Snoring") ≥ 0.30` **and** `score("Speech") < 0.5` (YAMNet scores are uncalibrated sigmoids; 0.3 is a sane starting point — make it a remote-free tunable constant and validate against recordings).
- **Episode state machine** (pure Kotlin, the most-tested component): IDLE → CANDIDATE on first positive; → ACTIVE when **≥3 of last 5 windows positive** (~2.4 s); episode ends after **10 s with no positive window**; discard episodes **< 5 s**; merge episodes separated by **< 20 s** into one. On ACTIVE entry it emits `EpisodeStarted(preRollNeeded=true)`; on end, `EpisodeEnded(peakDbfs, meanScore)`.
- **Intensity buckets** from peak RMS during positive windows (starting values, to calibrate): **light < −38 dBFS, moderate −38…−24 dBFS, loud > −24 dBFS**. Because we use VOICE_RECOGNITION/UNPROCESSED (no AGC), dBFS is stable per device; absolute cross-device calibration is a known limitation — note it in the report UI copy ("relative intensity").

**Testability:** `core/detection` is a pure-JVM module. `DetectionStateMachine` consumes `WindowResult(tMs, snoreScore, speechScore, rmsDbfs)` values and emits events — no Android, no MediaPipe. The classifier sits behind `interface SnoreClassifier { fun classify(window: FloatArray, tMs: Long): Scores }` faked in tests.

**Risks:** YAMNet confuses snoring with heavy breathing/purring/partner snoring (can't distinguish who snores — disclose in UI); fan/white-noise machines raise the floor and may keep the gate shut (adaptive floor mitigates); thresholds need a recorded-nights corpus to tune — plan a debug build flag that logs all window scores to a CSV for tuning.

## 4. Clip capture

- **Ring buffer:** 10 s of PCM16 @16 kHz mono = 320 KB (`ShortArray(160_000)` circular). Always being written by the audio loop.
- On `EpisodeStarted`: snapshot **3 s pre-roll** from the ring, then stream live PCM into the encoder until `EpisodeEnded` or a **20 s per-clip cap**.
- **Encoder: `MediaCodec` (AAC-LC, `audio/mp4a-latm`, 16 kHz, mono, 32 kbps) + `MediaMuxer` → `.m4a`.** `MediaRecorder` is ruled out: it only takes a mic *source*, not our PCM buffers, and opening a second capture path is wasteful/fragile. ~80 KB per 20 s clip.
- **Caps:** max **40 clips/night** (thereafter episodes are still logged, just clipless — prefer keeping the loudest: simple heuristic, once at cap replace the quietest stored clip if the new episode's peak is ≥6 dB louder); hard per-night byte cap 10 MB. Settings: auto-delete clips older than N nights (default 30), "delete all clips".
- Never any full-night file — PCM that doesn't hit the encoder is overwritten in the ring within 10 s.

## 5. Storage

**Room** (`androidx.room`, KSP) — schema:

```sql
sessions(
  id TEXT PK,             -- UUID
  started_at INTEGER, ended_at INTEGER NULL, tz_id TEXT,
  state TEXT,             -- active | complete | interrupted
  noise_floor_dbfs REAL, last_heartbeat_at INTEGER,
  -- denormalized on completion for fast History lists:
  total_snore_ms INTEGER, episode_count INTEGER,
  light_count INTEGER, moderate_count INTEGER, loud_count INTEGER,
  model_version TEXT, app_version TEXT
)
episodes(
  id TEXT PK, session_id TEXT FK ON DELETE CASCADE,
  start_at INTEGER, end_at INTEGER,
  peak_dbfs REAL, mean_score REAL,
  intensity TEXT,         -- light | moderate | loud
  clip_file TEXT NULL     -- relative path, null if capped/failed
)
gaps(session_id FK, start_at INTEGER, end_at INTEGER, reason TEXT)  -- mic silenced etc.
-- indices: episodes(session_id), sessions(started_at DESC)
```

Timeline chart renders straight from `episodes` (sparse; no per-minute bin table needed). Week/month trends come from the denormalized session columns via one DAO query.

**Files:** `context.filesDir/clips/{sessionId}/{episodeId}.m4a` — app-private internal storage: **zero storage permissions, no scoped-storage/MediaStore involvement, invisible to other apps**. Deleting a session deletes its directory (repository transaction: Room cascade + `File.deleteRecursively()`). **Backup:** exclude `clips/` and the Room DB from cloud backup via `android:dataExtractionRules` (API 31+) + `fullBackupContent` fallback — night audio must not silently land in Google backup. (Trade-off: uninstall loses history; acceptable for local-only MVP, note "Export" as post-MVP.)

## 6. App architecture & UI

**Pattern:** Compose + single-activity, MVVM — `ViewModel` + `Repository` + Kotlin Flow, **Hilt** DI, Compose Navigation. Screens (mirroring iOS spec):

1. **Home** — big Start button, mic/notification permission gating, charging nudge, last-night summary card. Tapping Start: request permissions → `startForegroundService` → navigate to Session screen.
2. **Session (in progress)** — dim clock, elapsed time, live "listening/snoring" state (from a `StateFlow` the service exposes via a bound interface or a repository-backed flow), Stop button (also on the notification).
3. **Report** — one night: snore timeline (episode bars over the night axis, colored by intensity), total snore time, episode count, intensity breakdown, gap markers, clip list with play buttons (`ExoPlayer`/`androidx.media3` or plain `MediaPlayer` — clips are tiny, `MediaPlayer` suffices for MVP).
4. **History** — calendar/list of nights + week/month trend charts (total snore time, episode count).
5. **Settings** — clip retention, delete-all-data, sensitivity (maps to score threshold), OEM battery help, medical disclaimer, licenses.

**Charts: Vico 2.x** (`com.patrykandpatrick.vico:compose-m3`, 2.x line on Maven Central — verify exact latest at build time; the multiplatform artifacts are at 2.5.x as of mid-2026). Vico's `ColumnCartesianLayer` covers trends; the night timeline is essentially a Gantt strip — if Vico fights you, hand-draw it with a `Canvas` composable (~50 lines) rather than importing MPAndroidChart. Recommendation: Vico for trends, custom Canvas for the timeline.

## 7. Permissions & Play Store

- **`RECORD_AUDIO`** runtime flow: pre-permission rationale screen on first Start ("audio is analyzed on your phone; only short snore clips are saved; nothing leaves your device") → system dialog → on permanent denial, Settings deep-link. Never request at app launch.
- **`POST_NOTIFICATIONS`** (API 33+): request alongside, with rationale ("shows the ongoing session"). If denied, the FGS still runs (notification suppressed; users can still see it in the Android 13+ FGS task manager) — degrade gracefully, don't block sessions.
- **Data safety form:** Play defines "collection" as data transmitted off-device — a genuinely local-only app can declare **no data collected, no data shared**. This is a major listing advantage; protect it by keeping crash reporting/analytics SDKs out of MVP (adding Crashlytics later forces a form change).
- **Health apps declaration:** sleep/snore tracking places the app in Play's Health apps policy scope — complete the Health Content & Services declaration in Play Console, and include an in-app + listing **medical disclaimer**: "Not a medical device. Does not diagnose, treat, or monitor any condition, including sleep apnea. Consult a physician for concerns." Show once in onboarding and permanently in Settings.
- Microphone-in-background will draw manual review: the FGS type declaration in Play Console (required for `FOREGROUND_SERVICE_MICROPHONE` at targetSdk 34+) needs a video + written justification — "user-initiated overnight snore recording with screen off" is squarely the intended use; prepare the demo video.

## 8. Project scaffolding & testing

```
android/
  settings.gradle.kts            # includes below; gradle/libs.versions.toml version catalog
  app/                           # Compose UI, navigation, Hilt app, SnoreSessionService
  core/detection/                # PURE KOTLIN (kotlin("jvm")): DetectionStateMachine,
                                 #   WindowAssembler, LoudnessGate, IntensityClassifier
  core/ml/                       # SnoreClassifier interface + MediaPipeSnoreClassifier, assets/yamnet.tflite
  core/audio/                    # AudioRecordLoop, PcmRingBuffer, AacClipEncoder (MediaCodec+MediaMuxer)
  core/data/                     # Room db/entities/DAOs, SessionRepository, ClipFileManager
```

Toolchain: Kotlin 2.x, AGP 8.x, KSP, Hilt, coroutines/Flow; tests: JUnit + `kotlinx-coroutines-test` + Turbine (Flow assertions) in `core/*`; Robolectric only where Android types leak (encoder, Room via in-memory DB); one Compose UI smoke test per screen; a device-side instrumented test that plays a bundled snoring WAV through the classifier and asserts score > threshold (guards model/asset regressions).

**Detection state-machine unit test shape** (pure JVM, no mocks of Android):

```kotlin
@Test fun `three of five positive windows opens episode, 10s quiet closes it`() {
    val sm = DetectionStateMachine(config = DetectionConfig(scoreThreshold = 0.3f))
    val events = mutableListOf<DetectionEvent>()
    fun window(t: Long, score: Float, db: Float = -30f) =
        sm.onWindow(WindowResult(tMs = t, snoreScore = score, speechScore = 0f, rmsDbfs = db))
            .also { events += it }

    window(0, 0.6f); window(487, 0.1f); window(975, 0.5f); window(1462, 0.4f) // 3 of last 5
    assertThat(events.filterIsInstance<EpisodeStarted>()).hasSize(1)
    (2_000L..14_000L step 487).forEach { window(it, 0.05f) }                  // 10s+ quiet
    val ended = events.filterIsInstance<EpisodeEnded>().single()
    assertThat(ended.endMs).isEqualTo(1462 + 975)  // last positive window end
    assertThat(ended.intensity).isEqualTo(Intensity.MODERATE)                 // peak -30 dBFS
}
```

Build order: (1) scaffolding + catalogs, (2) `core/detection` with full tests, (3) `core/ml` + instrumented WAV test, (4) `core/audio` + service + wake lock, (5) `core/data`, (6) UI screens, (7) tuning pass with real overnight recordings.

### Critical Files for Implementation
- android/core/detection/src/main/kotlin/DetectionStateMachine.kt
- android/app/src/main/kotlin/session/SnoreSessionService.kt
- android/core/ml/src/main/kotlin/MediaPipeSnoreClassifier.kt
- android/core/audio/src/main/kotlin/AacClipEncoder.kt
- android/core/data/src/main/kotlin/SessionRepository.kt

Sources:
- [Foreground service types are required (Android 14)](https://developer.android.com/about/versions/14/changes/fgs-types-required)
- [Foreground service types — microphone while-in-use restrictions](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Foreground service timeouts (dataSync/mediaProcessing only)](https://developer.android.com/develop/background-work/services/fgs/timeout)
- [Changes to foreground services](https://developer.android.com/develop/background-work/services/fgs/changes)
- [MediaPipe Audio classification guide for Android](https://ai.google.dev/edge/mediapipe/solutions/audio/audio_classifier/android)
- [Maven: com.google.mediapipe » tasks-audio](https://mvnrepository.com/artifact/com.google.mediapipe/tasks-audio)
- [Google Play target API level requirement](https://developer.android.com/google/play/requirements/target-sdk)
- [Play target API 36 deadline Aug 31, 2026](https://ecorpit.com/android-target-api-36-play-store-deadline-migration-2026/)
- [Vico chart library releases](https://github.com/patrykandpatrick/vico/releases)