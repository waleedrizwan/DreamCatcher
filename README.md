# Snore Laboratory

Native iOS + Android snore tracking app. Put your phone on the nightstand, tap Start, sleep. Overnight it records via the microphone, detects snoring **on-device** with ML, and in the morning shows a report of when and how much you snored, with playback of the worst episodes.

**Privacy stance:** local-only, no accounts, zero network calls. Full-night audio is never stored — only short clips of detected snore episodes. Audio never leaves the device (clips are excluded from OS backups; the metrics database backs up normally).

**Not a medical device.** Does not diagnose, treat, or monitor any condition, including sleep apnea.

## Repository layout

| Path | What it is |
|---|---|
| `spec/SHARED_BEHAVIOR_SPEC.md` | **Normative** behavior spec — everything downstream of `ClassifierFrame` must be identical on both platforms |
| `spec/schema/v1.sql` | The only DDL; both platforms consume it verbatim |
| `spec/fixtures/detector/` | Golden detector fixtures — the cross-platform consistency mechanism |
| `spec/reference/detector.py` | Python reference implementation of the detector; offline tuning tool and fixture validator |
| `docs/` | Design documents (iOS, Android, shared spec draft, feasibility + scope critiques) |
| `ios/` | Swift/SwiftUI app (iOS 17+). Lead platform. |
| `android/` | Kotlin/Compose app (minSdk 29). Ported after iOS calibration stabilizes (M7). |

## Architecture in one paragraph

Each platform's audio stack (AVAudioEngine / AudioRecord + an on-device sound classifier) is reduced to one normalized stream of `ClassifierFrame { tMs, rmsDbfs, peakDbfs, snoreConf, speechConf }` at 16 kHz mono, 1 s window / 500 ms hop. Everything downstream — the adaptive noise-floor gate, the event/episode state machine, metrics, intensity buckets, timeline binning, clip policy, SQLite schema — is specified once in `spec/` and implemented as a pure, platform-free class in Swift and Kotlin, both proven against the same golden fixtures. See `spec/SHARED_BEHAVIOR_SPEC.md`.

## Detection defaults (v1.1)

16 kHz mono · 1.0 s window / 500 ms hop · adaptive noise floor (min-follower +0.05 dB/frame) · gate = floor + 12 dB clamped [-56, -38] dBFS · positive = gated AND snoreConf ≥ threshold AND speech veto · event = ≥2 positive frames (or 1 strong) · episode = events merged ≤ 30 s gaps, confirmed at ≥3 events and ≥30 s span · intensity relative to room noise floor (light < +25 dB, moderate +25–40, loud ≥ +40).
