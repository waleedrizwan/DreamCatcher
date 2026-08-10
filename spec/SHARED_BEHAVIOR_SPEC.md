# SNORE LABORATORY — SHARED BEHAVIOR SPEC v1.1

This document is **normative** for everything downstream of `ClassifierFrame`: the detection state machine, metrics, intensity model, timeline binning, clip policy, data schema, lifecycle rules, and report semantics. Both platform implementations (Swift, Kotlin) MUST behave identically here, proven by the golden fixtures in `spec/fixtures/detector/`. Everything upstream (audio session config, foreground-service rules, interruption plumbing) is platform-discretionary and documented in `docs/design-ios.md` / `docs/design-android.md`.

v1.1 supersedes the v1.0 draft (`docs/design-shared.md`) with the reconciliations from the feasibility and scope reviews: `speechConf` + speech veto inside the shared detector, `gap` table + timeline gap rendering, wall-clock re-anchored timestamps, simplified confirmation-time clip capture, Snore Score removed from MVP UI, backup policy decided (metrics DB backs up; clips never), 12 h auto-stop, and storage-full degrade rules.

All constants live in one `DetectorParams` block per platform and are snapshotted into every session row (`detector_params_json`).

---

## 0. Normalization layer (the cross-platform contract point)

Both platforms reduce their audio/ML stack to one identical stream of frames:

```
ClassifierFrame {
  tMs:        Int64   // window START time, epoch ms UTC (see 0.2 timestamps)
  rmsDbfs:    Float   // RMS of the 1.0 s analysis window, dBFS, clamped [-100, 0]
  peakDbfs:   Float   // max |sample| of the window, dBFS, clamped [-100, 0]
  snoreConf:  Float   // classifier confidence for the snore class, 0.0–1.0
  speechConf: Float   // classifier confidence for the speech class, 0.0–1.0
}
```

- Audio: 16 kHz, mono, PCM float normalized to [-1, 1].
- `rmsDbfs = 20·log10(rms)`, `peakDbfs = 20·log10(maxAbs)`; pure silence clamps to -100.0.
- Cadence: one frame every **HOP_MS = 500 ms**, each covering a **WINDOW_MS = 1000 ms** trailing window (50 % overlap).
- RMS/peak are always computed by the normalization layer itself over its own exact 1.0 s window — never taken from the classifier's internal windowing.
- `speechConf` comes from the classifier's speech-family label (iOS `"speech"`; Android AudioSet `"Speech"`). It exists so the speech/TV veto lives **inside** the fixture-tested detector, not in per-platform code.

### 0.1 Platform adapters (the only per-platform detection code)

- **iOS**: `AVAudioEngine` input tap at the **hardware format** (typically 48 kHz — input taps cannot request 16 kHz) → `AVAudioConverter` → 16 kHz mono Float32 → classifier. Primary classifier: bundled YAMNet-class Core ML model, `computeUnits = .cpuOnly` (background-safe; the built-in SoundAnalysis classifier fails under a locked screen on iOS 17/18 — see `docs/design-feasibility.md` B1). Startup assertion: the model's label map contains the snore and speech classes; fail loudly in debug.
- **Android**: `AudioRecord` (16 kHz mono PCM16, `VOICE_RECOGNITION` source) → YAMNet via MediaPipe Tasks AudioClassifier (`AUDIO_CLIPS` mode, our own windowing). Startup assertion: `"Snoring"` and `"Speech"` present in the class map.
- Classifier window mismatch (0.975 s YAMNet vs 1.0 s nominal) is accepted: classifier confidence is attached to the `ClassifierFrame` whose window contains the classifier window's end; the state machine only ever sees normalized frames.
- A platform MAY skip classifier inference for frames whose `rmsDbfs` is below the loudness gate and substitute `snoreConf = 0, speechConf = 0` — the result is identical by definition (gated frames are negative). This is a battery optimization, not a behavioral difference.

### 0.2 Timestamps (normative — critique B4)

`tMs` is derived from **sample count anchored to wall clock at every capture (re)start**:

```
anchorMs   = wallClockMs at the moment the engine/AudioRecord (re)starts
tMs        = anchorMs + (samplesSinceAnchor / 16000) * 1000
```

Never per-callback wall clock (immune to clock jumps, deterministic for fixtures), and never a single session-start anchor (an interruption stops sample flow; without re-anchoring, everything after a 3 a.m. phone call would be shifted early by the gap length). Every interruption therefore produces: `flush()` on the detector (§1.4), a `gap` row (§3), and a fresh anchor on resume.

---

## 1. Detection state machine

### 1.1 Parameters (normative defaults — sensitivity "Medium")

| Constant | Default | Meaning |
|---|---|---|
| `WINDOW_MS` | 1000 | analysis window |
| `HOP_MS` | 500 | frame cadence |
| `CONF_THRESHOLD` | iOS **0.60** / Android **0.35** | per-frame snore confidence to count as positive. The ONLY per-platform detection constants; unified if both platforms ship YAMNet-family models |
| `CONF_STRONG` | iOS **0.80** / Android **0.55** | confidence that lets a single-frame event count as valid |
| `SPEECH_VETO_CONF` | 0.50 | speech veto floor (see positive-frame rule) |
| `NF_INIT` | -60.0 dBFS | initial noise-floor estimate |
| `NF_RISE_PER_FRAME` | 0.05 dB | noise-floor upward creep per frame (0.1 dB/s) |
| `NF_CLAMP` | [-80, -30] dBFS | noise-floor bounds |
| `GATE_OFFSET_DB` | 12.0 | gate = noise floor + offset |
| `GATE_CLAMP` | [-56, -38] dBFS | gate bounds |
| `MERGE_GAP_MS` | 30000 | max silence between events inside one episode; also the episode-close hangover |
| `MIN_EPISODE_EVENTS` | 3 | events required to confirm an episode |
| `MIN_EPISODE_SPAN_MS` | 30000 | span (first event start → last event end) required to confirm |
| `INTENSITY_LIGHT_MAX_DB` | 25.0 | relDb < 25 → light |
| `INTENSITY_MOD_MAX_DB` | 40.0 | 25 ≤ relDb < 40 → moderate; ≥ 40 → loud |

Note the deliberate product decision (feasibility B2): `MIN_EPISODE_SPAN_MS = 30000` means bouts shorter than 30 s are discarded entirely. Snoring that matters is sustained; coughs, grunts, and one-off snorts are not the product.

**Sensitivity setting** (Settings UI: Low / Medium / High) is a spec-defined override of exactly two constants per platform:

| Sensitivity | `CONF_THRESHOLD` (iOS / Android) | `CONF_STRONG` (iOS / Android) |
|---|---|---|
| Low  | 0.75 / 0.50 | 0.90 / 0.70 |
| Medium (default) | 0.60 / 0.35 | 0.80 / 0.55 |
| High | 0.45 / 0.22 | 0.70 / 0.40 |

The full effective parameter set is snapshotted into `session.detector_params_json` at session start.

### 1.2 Concepts

- **Noise floor** (`nf`): minimum-follower over frame RMS. Fast attack down, slow rise: `nf = clamp(min(rms, nf + NF_RISE_PER_FRAME), NF_CLAMP)`. Deterministic; no percentile buffers.
- **Gate**: `gate = clamp(nf + GATE_OFFSET_DB, GATE_CLAMP)`. Adaptive: a fan at -45 dBFS doesn't blind the detector; a distant quiet snorer still passes.
- **Speech veto**: a frame is vetoed when `speechConf >= SPEECH_VETO_CONF AND speechConf > snoreConf`. The cheapest defense against TV and partner-talking false positives, and it MUST be inside the shared detector so fixtures cover it.
- **Positive frame**: `rmsDbfs >= gate AND snoreConf >= CONF_THRESHOLD AND NOT vetoed`.
- **EVENT** = one snore sound: a maximal run of contiguous positive frames. `start = firstFrame.tMs`, `end = lastFrame.tMs + WINDOW_MS`. Valid iff `frameCount >= 2 OR maxConf >= CONF_STRONG` (kills one-off blips). An event carries `peakDbfs` (max over its frames), `maxConf`, and `nfAtStart` (noise floor when the event began).
- **EPISODE** = a snoring bout: valid events merged while the silence between one event's end and the next event's start is `<= MERGE_GAP_MS`. An episode opens PENDING at its first event, becomes CONFIRMED once it has `>= MIN_EPISODE_EVENTS` events AND span `>= MIN_EPISODE_SPAN_MS`, and CLOSES when `frame.tMs - lastEventEnd > MERGE_GAP_MS`. **Episode end = last event's end** — the hangover wait is never included in the span. A PENDING episode that times out unconfirmed is DISCARDED and its events are excluded from all metrics (and deleted from the DB, §3).
- Rationale: a snore breath cycle is 3–6 s, so a 30 s bout yields ~5–10 events, comfortably clearing 3; intra-bout pauses rarely exceed 30 s; the 30 s span minimum filters coughs, grunts, and short vocalizations.

### 1.3 Pseudocode (normative; implement as a pure class in both languages)

No wall clock, no I/O, no platform types. The recording service maps outputs to DB writes and clip capture.

```
enum Output:
  EventDetected(event)              // a valid event closed (its episode may still be PENDING)
  EpisodeConfirmed(episode)         // episode crossed the confirm bar; carries events so far
                                    //   → service triggers clip capture (§4)
  EpisodeClosed(episode)            // CONFIRMED episode finalized (events, span, snoreMs, peak, bucket)
  EpisodeDiscarded(episodeId)       // PENDING episode timed out → service deletes its events

class SnoreDetector(params):
  nf       = params.NF_INIT
  curEvent = null   // {startMs, lastFrameTMs, frameCount, peakDbfs, maxConf, nfAtStart}
  episode  = null   // {id, state: PENDING|CONFIRMED, events[], startMs, lastEventEndMs}

  fun process(frame: ClassifierFrame) -> List<Output>:
    out = []
    nf   = clamp(min(frame.rmsDbfs, nf + params.NF_RISE_PER_FRAME), params.NF_CLAMP)
    gate = clamp(nf + params.GATE_OFFSET_DB, params.GATE_CLAMP)
    vetoed   = frame.speechConf >= params.SPEECH_VETO_CONF && frame.speechConf > frame.snoreConf
    positive = frame.rmsDbfs >= gate && frame.snoreConf >= params.CONF_THRESHOLD && !vetoed

    if positive:
      if curEvent == null:
        curEvent = { startMs: frame.tMs, nfAtStart: nf, frameCount: 0, peakDbfs: -100, maxConf: 0 }
      curEvent.lastFrameTMs = frame.tMs
      curEvent.frameCount  += 1
      curEvent.peakDbfs     = max(curEvent.peakDbfs, frame.peakDbfs)
      curEvent.maxConf      = max(curEvent.maxConf, frame.snoreConf)
    else if curEvent != null:
      out += closeEvent()

    if episode != null && curEvent == null
         && frame.tMs - episode.lastEventEndMs > params.MERGE_GAP_MS:
      out += resolveEpisode()
    return out

  fun closeEvent() -> List<Output>:
    ev = curEvent; curEvent = null
    ev.endMs = ev.lastFrameTMs + params.WINDOW_MS
    valid = ev.frameCount >= 2 || ev.maxConf >= params.CONF_STRONG
    if !valid: return []
    out = []
    if episode != null && ev.startMs - episode.lastEventEndMs > params.MERGE_GAP_MS:
      out += resolveEpisode()               // stale episode; close before attaching
    if episode == null:
      episode = { id: newId(), state: PENDING, events: [], startMs: ev.startMs }
    episode.events.add(ev)
    episode.lastEventEndMs = ev.endMs
    out += [EventDetected(ev)]
    if episode.state == PENDING
         && episode.events.size >= params.MIN_EPISODE_EVENTS
         && episode.lastEventEndMs - episode.startMs >= params.MIN_EPISODE_SPAN_MS:
      episode.state = CONFIRMED
      out += [EpisodeConfirmed(episode)]
    return out

  fun resolveEpisode() -> List<Output>:
    ep = episode; episode = null
    if ep.state == CONFIRMED:
      ep.endMs   = ep.lastEventEndMs
      ep.snoreMs = sum(ep.events.map(e -> e.endMs - e.startMs))
      ep.peak    = ep.events.maxBy(peakDbfs)   // ties: EARLIEST event wins (normative —
                                               // beware Swift max(by:) returns the last max)
      ep.bucket  = intensityBucket(ep.peak)   // §2.2
      return [EpisodeClosed(ep)]
    return [EpisodeDiscarded(ep.id)]

  fun flush() -> List<Output>:                // session end / capture interruption
    out = []
    if curEvent != null: out += closeEvent()
    if episode  != null: out += resolveEpisode()
    return out
```

Contract details:

- Frames arrive with strictly increasing `tMs` at nominal 500 ms hops. Gaps in `tMs` (post-interruption re-anchor) are legal **only** after a `flush()`; the detector needs no special resume logic. `nf` intentionally survives `flush()` — it is the same room.
- `flush()` at an interruption means an episode straddling a phone call is split in two (or truncated). Accepted v1 behavior: honest, simple, and visible as a gap on the timeline.
- A dropped/late classifier result for a frame is normalized by the adapter to `snoreConf = 0` — never by skipping the frame.

### 1.4 Golden fixtures (the enforcement mechanism)

Shared JSON files in `spec/fixtures/detector/`, run by an identical fixture-runner test on each platform against its pure `SnoreDetector`, and by `spec/reference/detector.py` (the Python reference used for offline tuning). Format:

```json
{ "name": "basic_bout",
  "params": { "CONF_THRESHOLD": 0.6, "CONF_STRONG": 0.8 },
  "frames": [ [tMs, rmsDbfs, peakDbfs, snoreConf, speechConf], ... ],
  "flushAtMs": [ 900000 ],
  "expect": {
    "outputs": [ {"type": "EpisodeConfirmed", "atMs": ...}, ... ],
    "episodes": [ { "startMs": 0, "endMs": 0, "eventCount": 0, "snoreMs": 0,
                    "peakDbfs": 0.0, "nfAtPeak": 0.0, "bucket": "moderate" } ],
    "discardedEpisodes": 1 } }
```

Required cases (minimum set, identical files on both platforms): steady bout confirms · 2-event blip discards · single strong-conf frame forms a valid event · 29 s gap merges, 31 s gap splits · loud TV (high RMS, high speechConf) produces nothing · quiet snorer over a fan (adaptive gate) · event straddling `flush()` · interruption gap with re-anchored resume · sensitivity Low/High overrides · recovery replay (orphan events in → merged episodes out, §3.2) · 2 h noise-floor-creep synthetic night.

---

## 2. Metrics definitions

All metrics derive ONLY from confirmed episodes and their events.

- **Total snore time** `snoreTimeMs` = Σ event durations across confirmed episodes (actual sound time, not episode spans). Displayed "1 h 12 m".
- **Episode count** = number of confirmed episodes.
- **% of night** = `snoreTimeMs / (endedAtMs − startedAtMs)`, rounded to a whole percent. Denominator is the **full session span**; capture gaps are shown visually on the timeline, never subtracted (simplest and honest).
- **Room level** (display only) = median of `nfAtStart` over all events; null if no events.

### 2.2 Intensity (relative — phone mics are not SPL-calibrated)

Per event: `relDb = event.peakDbfs − event.nfAtStart`.

- **light**: `relDb < 25` · **moderate**: `25 ≤ relDb < 40` · **loud**: `relDb ≥ 40`

Episode bucket = bucket of its peak event. The report's intensity breakdown sums event durations into each event's own bucket (`lightMs + moderateMs + loudMs = snoreTimeMs`). UI always says "**+38 dB above room**", never absolute dB. Stability prerequisite (platform docs): AGC-free capture — iOS `.measurement` mode, Android `VOICE_RECOGNITION` source.

### 2.3 Timeline binning

- Bin width **5 min**, aligned to session start; bin *i* covers `[start + i·300000, start + (i+1)·300000)`; last bin partial.
- Bin value = seconds of event-time overlapping the bin (0–300), by interval intersection.
- Bin color = highest-severity bucket among overlapping events (loud > moderate > light); empty bins render as baseline.
- Capture gaps (§3 `gap` rows) render as gray segments over the affected range.
- Bins are computed on demand from `event` rows — **never stored** (no minute-aggregate table).

### 2.4 Snore Score — NOT in MVP

The composite 0–100 score is cut from the MVP UI (user decision). `session.snore_score` stays in the schema as a nullable column, always NULL in v1. The v1.0 draft formula is preserved in `docs/design-shared.md` §2.3 for post-MVP.

---

## 3. Data model & session lifecycle

Schema: `spec/schema/v1.sql` is the **only** DDL. iOS (GRDB) executes it verbatim; Android Room entities are written to match and CI-diffs Room's exported schema against it. `PRAGMA user_version = 1`; sequential numbered migrations. All timestamps INTEGER epoch ms UTC; IDs UUIDv4 TEXT.

Tables: `session`, `episode`, `event`, `clip`, `gap` — see the DDL for columns. `gap` rows record capture interruptions (`reason`: `interruption` | `mic_silenced` | `route_change` | `unknown`) and render gray on the timeline. On Android, >2 s of pure digital silence (all-zero samples) is treated as `mic_silenced` (covers the Quick-Settings mic toggle, which feeds silence without any error).

**Write policy during recording (this IS the crash-recovery design):**
- Events are INSERTed the moment they close (`episode_id` NULL).
- On `EpisodeConfirmed`: INSERT the episode row (`end_ms` provisional = last event end) and UPDATE its events' `episode_id`, one transaction.
- On `EpisodeClosed`: UPDATE the episode row with final end/snore_ms/peak/bucket.
- On `EpisodeDiscarded`: DELETE its events.
- Rollup columns on `session` are written only at finalize and MUST equal a recompute from rows (debug builds assert this on every report render).
- Heartbeat: `session.last_heartbeat_ms` UPDATEd every 60 s.

### 3.1 Lifecycle rules

- **Start**: pre-flight (mic permission; ≥ 200 MB free disk or refuse with guidance; charging nudge if unplugged and < 50 %), INSERT `state='recording'`, then start audio.
- **Normal end**: `flush()` → finalize open episode → rollups → `state='completed'`. Report auto-presents on Stop, and also on next app open if the user stopped without looking.
- **< 5 min session**: `state='discarded'`; delete its events/episodes/clips and files; toast "Session under 5 minutes — not saved." Never appears in history.
- **Auto-stop at 12 h**: sessions still recording at 12 h are finalized with `end_reason='auto_stopped'`; report shows an "Ended automatically" banner. (Forgot-to-stop protection: daytime TV must not become "snoring".)
- **Crash / battery death / permission revoked mid-night** (permission revocation kills the process — it IS the crash path): on next launch, any `state='recording'` row with a stale heartbeat is recovered: `ended_at_ms = max(last_heartbeat_ms, max(event.end_ms))`; orphan events (`episode_id` NULL) are re-merged by an offline replay of §1's merge/confirm rules (same parameters, deterministic, fixture-tested); rollups computed; `state='recovered'`. Report banner: "Recording ended unexpectedly at HH:MM". Already-written clips are kept.
- **Storage-full mid-night**: clip-write failure → stop writing clips, keep metrics (silent degrade). DB-write failure → retry in memory; if persistent, finalize gracefully as `recovered`. Never crash-loop.
- **Zero snoring**: fully valid; rollups 0; report shows the quiet empty state.
- **night_of** (grouping key): local calendar date of `(started_at − 12 h)` in the session's own `tz_id`. 23:30 Aug 9 → "2026-08-09"; 01:30 Aug 10 → "2026-08-09". Midnight/DST handled by epoch ms + per-session tz. Multiple sessions per night: calendar aggregates (summed snore time); the list shows each session.

---

## 4. Clip policy (v1 — capture at confirmation)

- Clips exist **only** for CONFIRMED episodes — one clip per episode. Raw audio outside clips never touches disk; PCM lives only in a **30 s in-memory ring buffer** (16 kHz mono 16-bit ≈ 0.96 MB).
- **Trigger**: on `EpisodeConfirmed`, snapshot from the ring buffer and encode **one fixed 12 s clip**: `snapshotStart = max(confirmingEvent.startMs − 3000, oldest ring coverage)`, length 12 s (clamped to available audio). The confirming event (the one that crossed the bar) is always fresh in the ring, so coverage is guaranteed — this is the simplification that fixes the v1.0 draft's ring-coverage bug. "Loudest event wins" re-snapshotting is post-MVP behind the same interface.
- **Cap**: 30 clips/night; after the cap, episodes are still fully logged, just clipless. (Loudest-wins eviction: post-MVP.)
- **Format**: AAC-LC, mono, 16 kHz, 32 kbps, `.m4a` (iOS `AVAudioFile`/`AVAssetWriter`; Android `MediaCodec` + `MediaMuxer`). ≈ 48 KB/clip; typical night < 2 MB total (DB + clips).
- **Naming**: `clips/<session_id>/<clip_start_ms>.m4a` under app-private storage (iOS Application Support; Android `filesDir`). DB row is authoritative; orphan files are garbage-collected at launch.
- **Retention**: clips (rows + files) auto-deleted after **90 days**; cleanup at session finalize and app launch. Metrics rows are kept indefinitely (tiny). Per-night delete and "Delete all data" hard-delete rows and files immediately.

---

## 5. Report content spec

### 5.1 Night report (auto-presented on Stop and on next app open)

1. **Header**: night_of date; "23:41 – 07:12 · 7 h 31 m in bed" (session tz). Banners: "Recording ended unexpectedly at HH:MM" (`recovered`) / "Ended automatically after 12 h" (`auto_stopped`) / "Short session" (< 60 min).
2. **Stat row**: Total snore time · % of night · Episode count.
3. **Timeline**: 5-min bars per §2.3, gray gap segments, hourly local ticks.
4. **Intensity breakdown**: three-segment bar of light/moderate/loud as % of snore time + absolute minutes.
5. **Clips**: one row per clip sorted by time — local time, 12 s, bucket chip, "+NN dB above room", play/scrub, per-clip delete. Footer: "Clips are kept for 90 days on this device."
6. **Zero-snore state**: "No snoring detected", flat timeline, no clips section.
7. **Caveat copy** (once per report, small print): "Snore Laboratory can't tell who — or what — is snoring."
8. **Footer**: medical disclaimer (§6).

Every number is recomputable from `episode`/`event` rows; rollups are a cache (debug assert).

### 5.2 History

- **Per-night list + calendar**: date, total snore time (color-scaled by snore minutes), episode count, time in bed. No dot = no recording (never rendered as zero).
- **Week view**: last 7 nights — bars of snore minutes; header averages over recorded nights only.
- **Month view**: last 30 nights, same encoding; "nights recorded: N/30". Missing nights are gaps, excluded from averages.

---

## 6. Privacy spec

- **Stored on device**: SQLite metrics DB; AAC clips only for confirmed episodes (≤ 30 × 12 s per night). **Never stored**: full-night audio (raw PCM exists only in the 30 s in-memory ring buffer).
- **Network**: MVP makes **zero network calls** — no accounts, no analytics or crash SDKs, no cloud. iOS ships Privacy Nutrition Label "Data Not Collected" and a `PrivacyInfo.xcprivacy` with no tracking; Android's Data Safety form declares no collection, no sharing. (Do not claim "no networking entitlement" — that concept doesn't exist on iOS.)
- **OS backups** (decided): the metrics DB **is included** in normal OS backups (history survives a new phone); the clips directory is **excluded** (iOS `isExcludedFromBackup = true`; Android `dataExtractionRules` + `fullBackupContent` excluding `clips/`). Privacy copy everywhere: "**Audio never leaves your device.**"
- **Mic indicators**: the OS indicator (iOS orange dot, Android green pill) is visible all night — disclosed in onboarding: "Your phone's microphone indicator stays on while Snore Laboratory listens. Audio is analyzed on this phone, and only short clips of detected snoring are saved."
- **Permission strings**: iOS `NSMicrophoneUsageDescription` = "Snore Laboratory listens overnight to detect snoring. Audio is analyzed on your phone; only short snore clips are saved, and audio never leaves your device." Android: runtime `RECORD_AUDIO` with an in-app rationale screen first; `POST_NOTIFICATIONS` for the ongoing-session notification (degrade gracefully if denied).
- **Disclaimer** (onboarding · report footer · settings · both store listings): "Snore Laboratory is not a medical device. It does not diagnose, treat, or monitor any medical condition, including sleep apnea. If you are concerned about your sleep or breathing, talk to a physician." Never use "apnea"/"diagnose" anywhere else in UI or store copy.
- **Deletion**: per-night delete and "Delete all data" hard-delete rows and audio files immediately.

---

## 7. Post-MVP appendix (explicitly out of v1)

Snore Score (formula in `docs/design-shared.md` §2.3; schema column reserved) · loudest-event clip re-snapshotting + cap eviction · factors/notes logging · export/share · cloud sync · smart alarm.
