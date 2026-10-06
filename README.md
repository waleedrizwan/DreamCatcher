# Dream Catcher

[![CI](https://github.com/waleedrizwan/DreamCatcher/actions/workflows/ci.yml/badge.svg)](https://github.com/waleedrizwan/DreamCatcher/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/waleedrizwan/DreamCatcher)](https://github.com/waleedrizwan/DreamCatcher/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A free, open-source snore tracker for iPhone, an alternative to SnoreLab with nothing locked behind a subscription.**

Put your phone on the nightstand, tap Start and go to sleep. Overnight it listens through the microphone and detects snoring **on the device** with Google's YAMNet sound model. In the morning it shows when and how much you snored, and lets you play back the worst episodes.

**Privacy:** no accounts, no analytics, no network calls at all. Full-night audio is never stored, only short clips of detected snoring, and audio never leaves the phone (clips are excluded from backups; the metrics database backs up normally).

**Not a medical device.** It doesn't diagnose, treat or monitor any condition, including sleep apnea.

> Want a dedicated bedside device that tracks every sound, not just snoring? See the sister project **[Night Owl](https://github.com/waleedrizwan/NightOwl)**, a Raspberry Pi recorder with a click-to-listen night report.

## Install

**Sideload the latest release.** Download `DreamCatcher.ipa` from [Releases](https://github.com/waleedrizwan/DreamCatcher/releases/latest) and install it with [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io). They sign it with your own Apple ID; a free Apple ID needs a re-sign every 7 days.

**Or build it yourself.** Open `ios/DreamCatcher.xcodeproj` in Xcode 16 or newer, choose your team under *Signing & Capabilities*, and run it on your iPhone (iOS 17+).

Run the tests:

```sh
swift test --package-path ios/Packages/SnoreCore      # detector vs golden fixtures
swift test --package-path ios/Packages/SnoreStorage
```

## Releasing

Add the version's notes to [CHANGELOG.md](CHANGELOG.md), bump `MARKETING_VERSION` in `ios/project.yml` (and the Xcode project), then push a tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

GitHub Actions builds the unsigned `.ipa` and publishes the release with that version's changelog section.

## Repository layout

| Path | What it is |
|---|---|
| `spec/SHARED_BEHAVIOR_SPEC.md` | **Normative** behavior spec — everything downstream of `ClassifierFrame` must be identical on both platforms |
| `spec/schema/v1.sql` | The only DDL; both platforms consume it verbatim |
| `spec/fixtures/detector/` | Golden detector fixtures — the cross-platform consistency mechanism |
| `spec/reference/detector.py` | Python reference implementation of the detector; offline tuning tool and fixture validator |
| `docs/` | Design documents (iOS, Android, shared spec draft, feasibility + scope critiques) |
| `tools/yamnet/` | Reproducible build of the bundled classifier: YAMNet (Google, Apache 2.0) → Core ML, plus validation scripts |
| `ios/` | Swift/SwiftUI app (iOS 17+). Lead platform. |
| `scripts/build-ipa.sh` | Builds the unsigned `.ipa` that releases ship |

An Android port (Kotlin/Compose, minSdk 29) is designed in `docs/design-android.md` and not started yet.

## Architecture in one paragraph

Each platform's audio stack (AVAudioEngine / AudioRecord + an on-device sound classifier) is reduced to one normalized stream of `ClassifierFrame { tMs, rmsDbfs, peakDbfs, snoreConf, speechConf }` at 16 kHz mono, 1 s window / 500 ms hop. Everything downstream — the adaptive noise-floor gate, the event/episode state machine, metrics, intensity buckets, timeline binning, clip policy, SQLite schema — is specified once in `spec/` and implemented as a pure, platform-free class in Swift and Kotlin, both proven against the same golden fixtures. See `spec/SHARED_BEHAVIOR_SPEC.md`.

## Detection defaults (v1.1)

Classifier: YAMNet (AudioSet, 521 classes) as a Core ML program run CPU-only — the one path iOS allows a backgrounded, locked-screen app (Apple's built-in SoundAnalysis classifier dies at screen lock; verified on-device 2026-09-19). Windows are peak-normalized before inference; snore threshold 0.35 / strong 0.55 (Medium).

16 kHz mono · 1.0 s window / 500 ms hop · adaptive noise floor (min-follower +0.05 dB/frame) · gate = floor + 12 dB clamped [-56, -38] dBFS · positive = gated AND snoreConf ≥ threshold AND speech veto · event = ≥2 positive frames (or 1 strong) · episode = events merged ≤ 30 s gaps, confirmed at ≥3 events and ≥30 s span · intensity relative to room noise floor (light < +25 dB, moderate +25–40, loud ≥ +40).

## License

[MIT](LICENSE) © 2026 Waleed Rizwan. The bundled YAMNet model is Google's, under Apache 2.0; see [NOTICE](NOTICE).
