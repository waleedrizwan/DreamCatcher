The project directory does not exist yet — fully greenfield, so no code exploration is needed. Below is the complete deliverable: the Shared Behavior Spec.

---

# DREAM CATCHER — SHARED BEHAVIOR SPEC v1.0

This document is the single source of truth for behavior that MUST be identical between the iOS (Swift) and Android (Kotlin) apps. Anything not specified here (UI styling, navigation, platform service wiring) is platform-discretionary. All constants below are normative defaults; they live in one constants block per platform (`DetectorParams`) and are snapshotted into every session record.

---

## 0. Normalization layer (the cross-platform contract point)

Both platforms reduce their audio/ML stack to one identical stream of `ClassifierFrame` values. Everything downstream of this type is spec-identical, pure, and unit-tested against shared fixtures.

```
ClassifierFrame {
  tMs:      Int64   // window START time, epoch ms UTC (derived from sample count, see 3.6)
  rmsDbfs:  Float   // RMS of the 1.0 s analysis window, dBFS, clamped to [-100, 0]
  peakDbfs: Float   // max |sample| of the window, dBFS, clamped to [-100, 0]
  snoreConf: Float  // classifier confidence for the snore class, 0.0–1.0
}
```

- Audio: 16 kHz, mono, PCM float normalized to [-1, 1].
- `rmsDbfs = 20 * log10(rms)`, `peakDbfs = 20 * log10(maxAbs)`; if input is silence, clamp to -100.0.
- Cadence: one frame every **HOP_MS = 500 ms**, each covering a **WINDOW_MS = 1000 ms** trailing window (50% overlap).
- Timestamps are derived from cumulative sample count anchored to session start (`tMs = sessionStartMs + (samplesConsumed / 16000) * 1000`), never from per-callback wall clock. This makes the stream immune to NTP/clock jumps and is what makes fixtures deterministic.

Platform adapters (the only per-platform detection code):
- **iOS**: `AVAudioEngine` tap at 16 kHz mono -> `SNAudioStreamAnalyzer` with `SNClassifySoundRequest(classifierIdentifier: .version1)` (iOS 15+), requested `windowDuration` = 1.0 s (clamped to the classifier's `windowDurationConstraint` at runtime), `overlapFactor` = 0.5. Read the confidence of the label `"snoring"`. RMS/peak are computed in the tap independently of SoundAnalysis. **Startup assertion**: `knownClassifications` contains `"snoring"`; fail loudly in debug if not.
- **Android**: `AudioRecord` (16 kHz mono, `VOICE_RECOGNITION` source) -> YAMNet via TFLite Task Audio or MediaPipe `AudioClassifier` (window 0.975 s, invoked every 500 ms on the trailing buffer). Read the score of AudioSet label `"Snoring"`. **Startup assertion**: label present in the model's class map.
- The 0.975 s vs 1.0 s window mismatch is accepted; the state machine only sees the normalized frame.

Battery note (non-normative): Android MAY skip TFLite inference for frames whose `rmsDbfs` is below the loudness gate (result is identical because gated frames are negative by definition). iOS streams everything to SoundAnalysis regardless.

---

## 1. Detection state machine

### 1.1 Parameters (normative defaults)

| Constant | Default | Meaning |
|---|---|---|
| `WINDOW_MS` | 1000 | analysis window |
| `HOP_MS` | 500 | frame cadence |
| `CONF_THRESHOLD` | iOS **0.60** / Android **0.35** | per-frame snore confidence to count as positive (per-platform calibration constant — the ONLY per-platform detection numbers) |
| `CONF_STRONG` | iOS **0.80** / Android **0.55** | confidence that lets a single-frame event count as valid |
| `NF_INIT` | -60.0 dBFS | initial noise-floor estimate |
| `NF_RISE_PER_FRAME` | 0.05 dB | noise-floor upward creep per frame (0.1 dB/s) |
| `NF_CLAMP` | [-80, -30] dBFS | noise-floor bounds |
| `GATE_OFFSET_DB` | 12.0 | gate = noise floor + offset |
| `GATE_CLAMP` | [-56, -38] dBFS | gate bounds |
| `MERGE_GAP_MS` | 30000 | max silence between events inside one episode; also the episode-close hangover |
| `MIN_EPISODE_EVENTS` | 3 | events required to confirm an episode |
| `MIN_EPISODE_SPAN_MS` | 30000 | span (first event start -> last event end) required to confirm |
| `INTENSITY_LIGHT_MAX_DB` | 25.0 | relDb < 25 -> light |
| `INTENSITY_MOD_MAX_DB` | 40.0 | 25 <= relDb < 40 -> moderate; >= 40 -> loud |

### 1.2 Concepts

- **Noise floor** (`nf`): minimum-follower over frame RMS. Fast attack down, slow rise: `nf = min(rms, nf + NF_RISE_PER_FRAME)`, clamped. Deterministic, no percentile buffers.
- **Gate**: `gate = clamp(nf + GATE_OFFSET_DB, -56, -38)`. Adaptive so a fan at -45 dBFS doesn't blind the detector and a distant quiet snorer still passes.
- **Positive frame**: `rmsDbfs >= gate AND snoreConf >= CONF_THRESHOLD`.
- **EVENT** = one snore sound: a maximal run of contiguous positive frames. `start = firstFrame.tMs`, `end = lastFrame.tMs + WINDOW_MS`. Valid iff `frameCount >= 2 OR maxConf >= CONF_STRONG` (kills one-off blips). Event carries `peakDbfs` (max over its frames), `maxConf`, and `nfAtStart` (noise floor when the event began).
- **EPISODE** = a snoring bout: valid events merged when the gap between one event's end and the next event's start is `<= MERGE_GAP_MS`. An episode opens PENDING at its first event, becomes CONFIRMED once it has `>= MIN_EPISODE_EVENTS` events AND span `>= MIN_EPISODE_SPAN_MS`. It CLOSES when `frame.tMs - lastEventEnd > MERGE_GAP_MS`. **Episode end = last event's end** — the 30 s hangover wait is never included in the span. A PENDING episode that times out without confirming is DISCARDED and its events are excluded from all metrics.
- Rationale for numbers: snore breath cycle is 3–6 s (so a 30 s bout yields ~5–10 events, comfortably clearing 3), pauses/position shifts rarely exceed 30 s within a bout, and 30 s minimum span filters coughs, grunts, and partner speech.

### 1.3 Pseudocode (normative; implement as a pure class in both languages)

No wall clock, no I/O, no platform types. Emits typed outputs; the recording service maps outputs to DB writes and clip capture.

```
enum Output:
  EventDetected(event)                  // a valid event closed (episode may still be PENDING)
  EpisodeConfirmed(episodeId, firstEvent..)
  NewPeakEvent(episodeId, event)        // valid event that is the episode's new loudest
  EpisodeClosed(episode)                // CONFIRMED episode finalized (events, span, peak, bucket)
  EpisodeDiscarded(episodeId)           // PENDING episode timed out

class SnoreDetector(params):
  nf = params.NF_INIT
  curEvent = null        // {startMs, lastFrameTMs, frameCount, peakDbfs, maxConf, nfAtStart}
  episode  = null        // {id, state: PENDING|CONFIRMED, events[], startMs, lastEventEndMs, peakEvent}

  fun process(frame: ClassifierFrame) -> List<Output>:
    out = []
    nf = clamp(min(frame.rmsDbfs, nf + params.NF_RISE_PER_FRAME), params.NF_CLAMP)
    gate = clamp(nf + params.GATE_OFFSET_DB, params.GATE_CLAMP)
    positive = frame.rmsDbfs >= gate && frame.snoreConf >= params.CONF_THRESHOLD

    if positive:
      if curEvent == null:
        curEvent = { startMs: frame.tMs, nfAtStart: nf, frameCount: 0,
                     peakDbfs: -100, maxConf: 0 }
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
      out += resolveEpisode()                 // stale episode; close before attaching
    if episode == null:
      episode = { id: newId(), state: PENDING, events: [], startMs: ev.startMs,
                  peakEvent: null }
    episode.events.add(ev)
    episode.lastEventEndMs = ev.endMs
    out += [EventDetected(ev)]
    if episode.peakEvent == null || ev.peakDbfs > episode.peakEvent.peakDbfs:
      episode.peakEvent = ev
      if episode.state == CONFIRMED: out += [NewPeakEvent(episode.id, ev)]
    if episode.state == PENDING
         && episode.events.size >= params.MIN_EPISODE_EVENTS
         && episode.lastEventEndMs - episode.startMs >= params.MIN_EPISODE_SPAN_MS:
      episode.state = CONFIRMED
      out += [EpisodeConfirmed(episode.id), NewPeakEvent(episode.id, episode.peakEvent)]
    return out

  fun resolveEpisode() -> List<Output>:
    ep = episode; episode = null
    if ep.state == CONFIRMED:
      ep.endMs = ep.lastEventEndMs
      ep.snoreMs = sum(ep.events.map(e -> e.endMs - e.startMs))
      ep.bucket = intensityBucket(ep.peakEvent)      // see 2.3
      return [EpisodeClosed(ep)]
    return [EpisodeDiscarded(ep.id)]

  fun flush() -> List<Output>:                        // session end / audio interruption
    out = []
    if curEvent != null: out += closeEvent()
    if episode  != null: out += resolveEpisode()
    return out
```

Contract details:
- Frames MUST arrive with strictly increasing `tMs` at nominal 500 ms hops. On any audio interruption (phone call, Siri, route change), the service calls `flush()`, then resumes feeding frames with correct sample-derived timestamps; the detector needs no special resume logic.
- The detector is the unit-test surface. **Golden fixtures** (shared JSON files, committed to `spec/fixtures/detector/`) drive both implementations:

```
{ "params": { "CONF_THRESHOLD": 0.6, "CONF_STRONG": 0.8 },        // optional overrides
  "frames": [ [tMs, rmsDbfs, peakDbfs, snoreConf], ... ],
  "flushAtMs": 900000,
  "expect": {
    "episodes": [ { "startMs":..., "endMs":..., "eventCount":..., "snoreMs":...,
                    "peakDbfs":..., "bucket": "moderate" } ],
    "discardedEpisodes": 1 } }
```

Required fixture cases (minimum set, identical files on both platforms): steady bout confirms; 2-event blip discards; single strong-conf frame forms valid event; 29 s gap merges / 31 s gap splits; loud TV (high RMS, low conf) produces nothing; quiet snorer with fan (adaptive gate); event straddling flush; noise-floor creep over 2 h synthetic night.

---

## 2. Metrics definitions

All metrics derive ONLY from confirmed episodes and their events.

### 2.1 Core numbers
- **Total snore time** `snoreTimeMs` = sum of event durations across confirmed episodes (actual sound time, not episode spans). Displayed as "1 h 12 m".
- **Episode count** = number of confirmed episodes.
- **Snoring % of night** = `snoreTimeMs / (endedAtMs - startedAtMs)`, rounded to whole percent.
- **Session noise floor** (display only, "room level") = median of `nfAtStart` over all events; null if no events.

### 2.2 Intensity buckets (relative, because phone mics are not SPL-calibrated)
Per event: `relDb = event.peakDbfs - event.nfAtStart`.
- **light**: `relDb < 25`
- **moderate**: `25 <= relDb < 40`
- **loud**: `relDb >= 40`

Episode bucket = bucket of its peak event. Intensity breakdown for reports = event durations summed per each event's own bucket (`lightMs / moderateMs / loudMs`; the three sum to `snoreTimeMs`). UI shows relative loudness as "+38 dB above room", never absolute dB.

### 2.3 Snore Score (0–100)
```
D = min(1.0, snoreTimeMin / 120)                          // duration, saturates at 2 h
W = Σ(eventDurMs × w(bucket)) / snoreTimeMs               // loudness weight; 0 if no snoring
      w: light 0.33, moderate 0.66, loud 1.0
E = min(1.0, episodeCount / 15)                           // fragmentation
score = round(100 × D × (0.55 + 0.30×W + 0.15×E))
```
Zero snoring -> 0 by construction. Sanity anchors: 1 min loud ≈ 1; 30 min moderate ≈ 20; 1 h moderate/8 eps ≈ 42; 2 h+ loud/15 eps = 100. Bands: **0 Quiet · 1–20 Mild · 21–50 Moderate · 51–100 Heavy** (band names/colors shared). Sessions shorter than 60 min compute normally but display a "Short session" badge.

### 2.4 Timeline binning
- Bin width **5 min**, aligned to session start: bin i covers `[start + i·300000, start + (i+1)·300000)`; last bin partial.
- Bin value = seconds of event-time overlapping the bin (0–300), computed by interval intersection of events with the bin.
- Bin color = highest-severity bucket among events overlapping the bin (loud > moderate > light); empty bins render as baseline.
- Bins are computed on demand from the `event` table, never stored.

---

## 3. Data model (SQLite on both platforms)

Schema versioning: `PRAGMA user_version` starting at **1**; sequential numbered migrations; identical DDL maintained in `spec/schema/v1.sql` and copied verbatim into both apps. All timestamps epoch ms UTC (INTEGER). IDs are UUIDv4 TEXT generated on device.

```sql
CREATE TABLE session (
  id                 TEXT PRIMARY KEY,
  started_at_ms      INTEGER NOT NULL,
  ended_at_ms        INTEGER,              -- null while recording
  tz_id              TEXT NOT NULL,        -- IANA, e.g. "America/Toronto", captured at start
  tz_offset_min      INTEGER NOT NULL,     -- UTC offset at start (display fallback)
  night_of           TEXT NOT NULL,        -- 'YYYY-MM-DD', see 3.3
  state              TEXT NOT NULL,        -- 'recording'|'completed'|'recovered'|'discarded'
  last_heartbeat_ms  INTEGER NOT NULL,     -- updated every 60 s while recording
  -- rollups, written at finalize, recomputable from episodes/events:
  snore_time_ms      INTEGER, episode_count INTEGER, snore_score INTEGER,
  light_ms INTEGER, moderate_ms INTEGER, loud_ms INTEGER,
  noise_floor_dbfs   REAL, clip_count INTEGER, interruption_count INTEGER DEFAULT 0,
  detector_params_json TEXT NOT NULL,      -- exact constants used this night
  app_version TEXT NOT NULL, device_model TEXT NOT NULL,
  created_at_ms      INTEGER NOT NULL
);
CREATE INDEX idx_session_night ON session(night_of);

CREATE TABLE episode (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  event_count INTEGER NOT NULL, snore_ms INTEGER NOT NULL,
  peak_dbfs REAL NOT NULL, peak_rel_db REAL NOT NULL,
  bucket TEXT NOT NULL                    -- 'light'|'moderate'|'loud'
);
CREATE INDEX idx_episode_session ON episode(session_id);

CREATE TABLE event (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  episode_id TEXT REFERENCES episode(id) ON DELETE CASCADE,  -- null until episode resolves
  start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  peak_dbfs REAL NOT NULL, max_conf REAL NOT NULL, nf_dbfs REAL NOT NULL
);
CREATE INDEX idx_event_session ON event(session_id);

CREATE TABLE clip (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  episode_id TEXT NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
  file_name TEXT NOT NULL,                -- relative: clips/<session_id>/<clip_start_ms>.m4a
  start_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
  peak_dbfs REAL NOT NULL, bytes INTEGER NOT NULL, created_at_ms INTEGER NOT NULL
);
```

Write policy during recording (this IS the crash-recovery design): events are INSERTed the moment they close (episode_id NULL); on `EpisodeClosed`, INSERT episode and UPDATE its events' `episode_id` in one transaction; on `EpisodeDiscarded`, DELETE its events. Rollup columns touched only at finalize.

### 3.1 Session lifecycle & edge cases
- **Start**: insert `state='recording'` row, then start audio. Heartbeat UPDATE every 60 s.
- **Normal end**: `flush()` detector -> finalize open episode -> compute rollups -> `state='completed'`.
- **User ends immediately**: if duration < **5 min**, set `state='discarded'`, delete its events/episodes/clips and files, show toast "Session under 5 minutes — not saved." Discarded sessions never appear in history.
- **App killed / battery died mid-session**: on next launch, any `state='recording'` row is recovered: `ended_at_ms = max(last_heartbeat_ms, max(event.end_ms))`; re-run episode merge over events with `episode_id IS NULL` (offline replay of Section 1 merge rules); compute rollups; `state='recovered'`. Report shows banner "Recording ended unexpectedly at HH:MM". Already-written clips are kept.
- **Zero snoring**: fully valid; rollups all 0/NULL noise floor; report shows the empty state (Section 5).
- **Spanning midnight / DST**: epoch ms is immune; display uses `tz_id` (the session's own zone, so travel never re-dates old nights). DST transitions mid-night need no handling beyond formatting via `tz_id`.
- **night_of** (grouping key): local calendar date of `(started_at - 12 h)` in `tz_id`. Start 23:30 Aug 9 -> "2026-08-09"; start 01:30 Aug 10 -> "2026-08-09". Multiple sessions per night: history calendar aggregates as summed snore time and max score; the list shows each session.

---

## 4. Clip policy

- **Trigger**: clips exist only for CONFIRMED episodes — one clip per episode, capturing the episode's **loudest** event. Raw audio outside clips is never written to disk.
- **Mechanism**: recording service keeps a **30 s in-memory PCM ring buffer** (16 kHz mono 16-bit ≈ 0.96 MB). On `NewPeakEvent`, snapshot the range `[event.start_ms - PRE_ROLL, +CLIP_LEN]` once the ring buffer covers it; a later louder event in the same episode replaces the in-memory candidate. On `EpisodeClosed`, encode and persist the winning candidate.
- **Parameters**: `PRE_ROLL = 3 s`; `CLIP_LEN = 12 s` fixed total (clamped to session bounds); cap **30 clips/night**.
- **Cap eviction (loudest wins)**: if at cap when an episode closes, compare its `peak_dbfs` to the quietest kept clip; if louder, delete that clip (file + row) and keep the new one; else drop the new one.
- **Format**: AAC-LC, mono, 16 kHz sample rate, **32 kbps**, `.m4a` container (iOS `AVAssetWriter`; Android `MediaCodec` + `MediaMuxer`). ~48 KB per clip.
- **Naming**: `clips/<session_id>/<clip_start_ms>.m4a` under app-private storage (iOS Application Support; Android internal `filesDir`). Deterministic and sortable; DB row is authoritative, orphan files are garbage-collected at launch.
- **Storage budget**: clips ≤ 30 × 48 KB ≈ **1.5 MB/night**; DB worst case (heavy snorer, ~8 k events) ≈ 0.5 MB/night; typical night **< 2 MB total**.
- **Retention**: clips auto-deleted after **90 days** (rows too); additionally a **400 MB** hard cap on the clips directory, evicting oldest nights first. Sessions/episodes/events (sans clips) are kept indefinitely (tiny). Cleanup runs at every session finalize and app launch. Deleting a night in the UI cascades (DB `ON DELETE CASCADE` + file deletion). "Delete all data" wipes DB and files.

---

## 5. Report content spec

### 5.1 Morning report (session detail — auto-presented on next app open after a completed session)
1. **Header**: night_of date; "23:41 – 07:12 · 7 h 31 m in bed" (session tz).
2. **Snore Score**: big number + band label/color; "Short session" badge if < 60 min; recovery banner if `state='recovered'`.
3. **Stat row**: Total snore time (`snoreTimeMs`) · % of night · Episode count.
4. **Timeline chart**: 5-min bars per Section 2.4; x-axis hourly local ticks; y = 0–5 min; bar color = bin bucket.
5. **Intensity breakdown**: three-segment bar of `light/moderate/loud` as % of snore time + absolute minutes each.
6. **Clips list**: one row per clip, sorted by time: local time, 12 s duration, bucket chip, "+NN dB above room" (`peak_rel_db` rounded), play/scrub. Footer: "Clips are kept for 90 days on this device."
7. **Zero-snore state**: score 0 ("Quiet"), message "No snoring detected", flat timeline, no clips section.
8. Footer: medical disclaimer (Section 6).

Every number on this screen is recomputable from `episode`/`event` rows; the rollup columns are a cache, and a debug assertion recomputes and compares.

### 5.2 History
- **Per-night list/calendar**: date, score (band color), total snore time, time in bed. Calendar dots colored by score band; no dot = no recording (never rendered as zero).
- **Week view**: last 7 nights — bars of snore minutes, overlaid score line; header averages (avg score, avg snore time) over recorded nights only.
- **Month view**: last 30 nights, same encoding; header adds "nights recorded: N/30". Missing nights are gaps and are excluded from all averages.

---

## 6. Privacy spec

- **Stored on device**: SQLite metrics DB; AAC clips only for confirmed snore episodes (max 30 × 12 s per night). **Never stored**: full-night audio (raw PCM exists only in the 30 s in-memory ring buffer), anything off-device.
- **Network**: the MVP makes **zero network calls** — no accounts, no analytics/crash SDKs, no cloud. This is verifiable (no networking entitlement usage) and is the headline privacy claim.
- **OS backups**: excluded — the promise is "never leaves this device." iOS: `isExcludedFromBackup = true` on DB and clips dirs; Android: `allowBackup=false`.
- **Mic indicators**: the OS mic indicator (iOS orange dot, Android green pill) will be visible all night — expected and disclosed in onboarding copy: "Your phone's microphone indicator stays on while Dream Catcher listens. Audio is analyzed on this phone and only short clips of detected snoring are saved."
- **Permissions**: iOS `NSMicrophoneUsageDescription` = "Dream Catcher listens overnight to detect snoring. Audio is analyzed on your phone; only short snore clips are saved, and nothing leaves your device." Android: `RECORD_AUDIO`, foreground service with `foregroundServiceType="microphone"` (+ `FOREGROUND_SERVICE_MICROPHONE` on API 34+), persistent notification "Monitoring for snoring", `POST_NOTIFICATIONS`.
- **Disclaimer** (onboarding, report footer, store listing): "Dream Catcher is not a medical device. It does not diagnose, treat, or monitor any medical condition, including sleep apnea. If you are concerned about your sleep or breathing, talk to a physician."
- **Deletion**: per-night delete and "Delete all data" both hard-delete rows and audio files immediately.

---

## Implementation sequencing (recommended)

1. Commit this spec + `spec/schema/v1.sql` + golden detector fixtures (the fixtures are the cross-platform consistency tool; write them before either native detector).
2. Each platform: implement `SnoreDetector` pure class + fixture runner test -> green on shared fixtures.
3. Platform audio adapters (frame normalization, sample-count timestamps) + classifier wiring; verify label presence assertions.
4. Persistence layer + recovery replay; then clip ring buffer/encoder; then report/history UI off the metrics definitions.

Key risks to validate early: real-world calibration of `CONF_THRESHOLD` on each classifier (record a few nights, tune the two per-platform constants only); iOS `windowDurationConstraint` acceptance of 1.0 s; Android OEM battery-killer behavior on the foreground service (heartbeat + recovery path covers data loss).

### Critical Files for Implementation
- spec/SHARED_BEHAVIOR_SPEC.md
- spec/schema/v1.sql
- spec/fixtures/detector/basic_bout.json (plus sibling fixture files listed in 1.3)
- ios/DreamCatcher/Detection/SnoreDetector.swift
- android/app/src/main/kotlin/com/dreamcatcher/detection/SnoreDetector.kt