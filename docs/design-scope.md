The directory doesn't exist yet — fully greenfield, as expected. All three design documents are in the prompt, so no code exploration is needed. Here is the scope and build-order review.

---

# DREAM CATCHER — SCOPE & BUILD ORDER REVIEW

## 0. The most important finding: the three documents describe three different detectors

Before any roadmap, one issue dominates: the iOS doc, Android doc, and Shared Spec each define a **different detection state machine, different windowing, different intensity model, different clip policy, and different schema**. If implementation starts from the platform docs, the "shared behavior spec" is fiction from day one. Concrete conflicts:

| Dimension | iOS doc | Android doc | Shared Spec |
|---|---|---|---|
| Window / hop | 1.5 s / 0.75 s | 0.975 s / ~0.49 s | 1.0 s / 0.5 s |
| Episode start | 2 consecutive positive windows | 3 of last 5 windows | ≥3 valid events AND ≥30 s span (PENDING→CONFIRMED) |
| Episode end | 20 s quiet | 10 s quiet | 30 s gap (MERGE_GAP_MS) |
| Min episode | ≥10 s | ≥5 s | ≥30 s span, ≥3 events |
| Intensity | absolute dBFS buckets | absolute dBFS buckets | **relative** dB above noise floor |
| Speech veto | yes (competing label) | yes (Speech < 0.5) | **absent** — `ClassifierFrame` has no speech field |
| Clip policy | live-append ≤30 s, 50 clips/40 MB | ≤20 s, 40 clips/10 MB | fixed 12 s of loudest event, 30 clips |
| Ring buffer | 20 s Float32 | 10 s PCM16 | 30 s PCM16 |
| Schema | session/episode/minuteAggregate | sessions/episodes/gaps | session/episode/event/clip |
| Interruption gaps | timeline "interruption segments" | `gaps` table | **absent** from schema and report spec |

**Resolution rule for M0:** the Shared Spec wins on everything downstream of `ClassifierFrame` (state machine, metrics, intensity, clips, schema). The platform docs win on everything platform-specific upstream (audio session config, FGS rules, interruption handling, file protection). Two amendments the spec must absorb *from* the platform docs because both platforms independently converged on them:

1. **Add `speechConf: Float` to `ClassifierFrame`** and a speech-veto term to the positive-frame rule (both classifiers expose a speech label; it is the cheapest defense against TV/partner-talking false positives, and it must be in the fixtures or the platforms will diverge on it).
2. **Add a `gap` table** (`session_id, start_ms, end_ms, reason`) and gap rendering to the timeline/report spec (gray segments; iOS interruptions and Android mic-silencing both need it — "honest data beats invisible holes" is right, and the spec currently has nowhere to put it).

The spec's relative-intensity model (relDb above noise floor) supersedes both platform docs' absolute dBFS buckets — it is the correct call and the platform docs should be read as stale on this point.

---

## 1. Phased implementation roadmap

### Platform order: one platform deep first, not lockstep

Lockstep doubles the cost of every detector-parameter change during the phase when parameters churn the most (calibration). The fixtures make the second-platform port cheap *after* the spec stabilizes — that is their entire purpose. So: spikes on both platforms in week 1 (existential risks only), then one platform end-to-end through calibration, then port.

**Lead platform: iOS, conditional on Spike 0 passing.** Reasons: the dev environment is macOS; TestFlight distribution for overnight beta is frictionless; and the iOS background-classification question is the single go/no-go that can reshape the shared architecture, so it must be answered first regardless. **If Spike 0 fails:** prefer Fallback B (YAMNet converted to Core ML) over Fallback A (screen-on mode) — it unifies the classifier across platforms (same model, near-shared thresholds) and keeps the lock-screen UX. Only if Core ML conversion also stalls, flip to Android-first while iOS ships Fallback A.

### Walking skeleton (end of M2)

Start button → mic permission → background audio session (iOS) / microphone FGS + wake lock (Android) → real classifier → spec `SnoreDetector` → event/episode rows in SQLite → heartbeat → Stop → a report screen showing **three plain numbers** (duration, total snore time, episode count) read from the DB. No charts, no clips, no history, no styling. Acceptance test: lock the phone, play a 10-minute snoring recording from a speaker, unlock in the morning position, see a plausible episode count. **Every subsequent milestone dogfoods this nightly.**

### Milestones (solo dev, ideal weeks; ~13–16 wks to two-platform beta)

- **M0 — Spec freeze + spikes (1 wk).** Reconcile the conflict table above into Shared Spec v1.1; write `spec/schema/v1.sql`; write the golden detector fixtures (all cases in spec §1.3 plus additions in §4 below). In parallel: iOS Spike 0 (locked-screen SoundAnalysis 60+ min soak, two OS versions, physical devices) and an Android mini-spike (microphone FGS + wake lock overnight soak on stock Pixel + one aggressive OEM device, e.g. Xiaomi). Exit: classifier choice per platform locked; fixtures committed.
- **M1 — Lead-platform pure core + storage (1–1.5 wk).** `SnoreDetector` pure class green on all fixtures; GRDB schema from `v1.sql`; recovery-replay function (same detector, replayed over orphan events) also fixture-tested.
- **M2 — Walking skeleton (1.5–2 wk).** Audio capture, sample-count timestamps, classifier adapter with startup label assertion, session actor/service, heartbeat, crash recovery, minimal report numbers. Begin nightly real-bedroom dogfood.
- **M3 — Lifecycle hardening + calibration loop (2 wk, overlaps nightly runs).** Interruptions/route changes/engine restarts (iOS), mic-silencing/gap records (Android later), watchdog, storage-full and forgot-to-stop behaviors (§3), debug frame-CSV logging, **file-replay harness** (§4 — build it here, it pays for itself immediately), first threshold tuning against the replay corpus.
- **M4 — Clips (1 wk).** Ring buffer, loudest-event candidate, AAC encode, cap/eviction, playback, retention GC.
- **M5 — Report UI (1–1.5 wk).** Timeline (5-min bins with gap segments), intensity breakdown, clip list, zero-snore/recovered/short-session states, disclaimer footer.
- **M6 — History, settings, store prep (1.5 wk).** Calendar/list, week/month trends, sensitivity setting (param overrides snapshotted per session), delete flows, onboarding, privacy manifest / declarations.
- **M7 — Android port (3–4 wk).** Detector ports in days (fixtures are the proof); the real work is the audio adapter, FGS service, and Compose UI. Prepare the Play Console FGS-microphone justification video during, not after. All product decisions are already frozen — no design churn.
- **M8 — Two-platform field beta (2+ wk calendar).** TestFlight + Play internal track; tune only the two per-platform confidence constants from collected debug CSVs; OEM-killer matrix; Energy/battery profiling.

De-risk ordering inside every milestone: detection pipeline and lifecycle before any UI polish. Nothing in M5/M6 can rescue an app that misses episodes or dies at 3 a.m.

---

## 2. Over-engineered for MVP — cut or simplify

1. **Snore Score (spec §2.3) — cut from MVP.** It is not in the user's confirmed feature list (timeline, totals, episode count, intensity breakdown). It is an invented composite metric that adds explanation burden, UI surface (bands, colors, badges), and a second thing to calibrate. Color the history calendar by total snore minutes instead. Keep the formula in the spec as post-MVP; the schema column can stay (nullable).
2. **iOS `minuteAggregate` table — cut.** The spec already rules correctly: bins are computed on demand from events (≤ ~100 bins per night from at most a few thousand rows — trivial). A second materialized timeline representation is a consistency bug waiting to happen.
3. **Platform docs' episode state machines — delete, do not "merge."** Both are superseded by the spec's event/episode detector. Any implementation effort spent on the "3 of last 5 windows" or "2 consecutive windows" designs is waste.
4. **Clip loudest-event candidate machinery — simplify for v1.** The spec's `NewPeakEvent` re-snapshot flow has a hidden hazard: an early loud event can scroll out of the 30 s ring before episode close, so the candidate PCM must be held in memory and re-managed per peak change. v1: capture one fixed 12 s clip (3 s pre-roll) at **episode confirmation**, done. "Loudest event wins" is a fast-follow behind the same clip interface. Similarly, cap eviction ("replace quietest if ≥6 dB louder") → v1 is "first 30 clips, then stop."
5. **Android `UNPROCESSED` source upgrade path — cut.** Use `VOICE_RECOGNITION` unconditionally (the spec already says so). A per-device source switch reintroduces exactly the cross-device level variance the relative-intensity model exists to absorb, and doubles the calibration matrix.
6. **iOS Fallback B (custom Core ML model) — do not build preemptively.** It exists only as the answer to a failed Spike 0. The `SnoreClassifying` protocol seam is the right (and sufficient) insurance; building the model "just in case" before the spike is a week of speculative work.
7. **Android Hilt — optional; manual constructor DI is enough** for a 5-screen app with one service. Not a hill to die on, but it is pure ceremony at this size and slows the build.
8. **Dual chart approaches (Vico + custom Canvas) — decide once in M0.** The Android doc already suspects Vico will fight the Gantt-style timeline; commit to custom Canvas for the timeline and Vico only for trend bars, and mirror the split on iOS (Swift Charts handles both fine there).
9. **Two retention systems.** The docs collectively specify per-clip caps, per-night byte caps, per-night clip counts, N-day expiry, a 400 MB directory cap, and orphan GC. Keep three knobs: 30 clips/night, 90-day expiry, orphan GC at launch. Drop the byte caps (30 × ~50 KB makes them unreachable).

Not over-engineered, keep as designed: the `event` table (it *is* the crash-recovery and recompute design), sample-count-derived timestamps, `detector_params_json` snapshotting, the pure-module package layout on both platforms, the adaptive noise-floor gate.

---

## 3. Missing — will bite later

1. **Forgot-to-stop / max session duration.** No document handles the user who never taps Stop. The session runs 24 h+, the report is garbage, day-time TV becomes "snoring." Add to spec: auto-finalize at 12 h with an `endReason='autoStopped'` banner, plus (nice-to-have) trim trailing hours of daytime noise.
2. **Storage-full.** Nothing specifies behavior when disk fills at start or mid-night. Add: pre-flight check at Start (require e.g. 200 MB free or refuse with guidance); mid-night clip-write failure → degrade to clipless silently; mid-night DB-write failure → finalize gracefully as `recovered`, never crash-loop.
3. **Permission revoked mid-night.** On both platforms, revoking mic permission kills the app process outright — which means this path *is* the crash-recovery path and needs an explicit test. Android additionally has the **Quick Settings mic toggle (Android 12+)**, which feeds silence without any error: the Android doc's ">2 s of pure digital silence" heuristic covers it, but that heuristic must be promoted into the shared spec's gap semantics, and Android 11+ auto-revoke of unused-app permissions deserves an onboarding note.
4. **Android input-device pinning.** iOS forces the built-in mic; the Android doc never does. A plugged wired headset or USB-C dongle mic becomes the default input and records from inside a pocket or drawer. Add `AudioRecord.setPreferredDevice(TYPE_BUILTIN_MIC)` plus a device-callback re-assert, mirroring iOS §2.4.
5. **Mic-covered / face-down / under-pillow detection.** No pre-flight signal check anywhere. Cheap fix: during the first 60 s, if RMS is pinned near −100 dBFS or the noise floor is implausibly low, show a lock-screen-visible notification / next-morning banner: "Your microphone may have been covered." Costs an evening; saves the one-star "it recorded nothing" reviews.
6. **Partner/pet snoring caveat.** All three docs mention it internally; none puts it in the product. Add one line of report UI copy to the spec ("Dream Catcher can't tell who — or what — is snoring") and an onboarding mention. Also add a partner-snoring audio file to the test corpus as a *positive* (it will detect; the product just needs honest framing).
7. **Morning alarm interplay.** The user's alarm rings on the same phone: iOS fires an interruption (covered mechanically), but the alarm and subsequent snoozing/fumbling happen at max proximity — add "phone's own alarm at 7 a.m." to the soak-test matrix and confirm the classifier doesn't score alarm audio as snoring; ensure the session survives to a manual Stop.
8. **Gap accounting in metrics.** Once gaps exist (see §0), decide whether "% of night" uses the full span or span-minus-gaps as denominator. Unspecified = platform divergence. (Recommend: full span, gaps shown visually; simplest and honest.)
9. **Low Power Mode / Battery Saver in the test matrix.** Neither should kill a mic FGS or an active audio session, but both alter scheduling — soak-test under them explicitly rather than asserting from documentation.
10. **Thermal — a non-issue, so say so once.** Mic + a ~4 MB model every 0.5 s on a charging phone will not throttle; add a debug-log of thermal state during soaks to confirm and then stop worrying about it. Flagging this prevents someone gold-plating a thermal-degradation mode later.
11. **Beta observability without analytics SDKs.** The "zero network" stance is right, but the beta needs crash and tuning signals. TestFlight crash reports and Play Vitals are platform-side (no SDK, no data-safety-form change) — rely on those, plus a user-initiated "export debug log" share-sheet action in beta builds only.

---

## 4. Testing strategy

Four layers, in order of leverage:

**Layer 1 — Shared golden fixtures (the cross-platform contract).** JSON fixtures in `spec/fixtures/detector/` run by an identical fixture-runner test on both platforms against the pure `SnoreDetector`. The spec's required set is good; add: (a) a **recovery-replay fixture** (orphan events in, merged episodes out — proves live and replay paths agree); (b) a **flush-then-resume fixture** with a gap (interruption semantics); (c) **sensitivity-setting fixtures** (Low/Med/High param overrides, since Settings maps to these); (d) a **speech-veto fixture** once `speechConf` lands. Also build a ~50-line **Python reference implementation** of the detector pseudocode, validated against the same fixtures — it becomes the offline tuning tool for Layer 3 CSVs and the generator for synthetic fixtures (e.g., the 2 h noise-floor-creep case).

**Layer 2 — Classifier characterization tests (per platform, not shared).** A small committed corpus of short WAVs fed directly through each platform's classifier adapter in instrumented tests, asserting snore scores above/below thresholds. Guards against model-asset regressions and OS-update classifier drift. **Corpus sourcing caution:** ESC-50 is CC BY-NC (problematic in a commercial repo) and AudioSet ships features, not redistributable audio. Build the corpus from Freesound CC0/CC-BY clips plus self-recorded samples; use ESC-50/AudioSet only as private local tuning references, never committed.

**Layer 3 — File-replay harness (the highest-leverage single investment; build in M3).** A debug-build mode that injects a WAV/PCM file into the full pipeline *below the mic* (capture-format frames in, everything else identical), running faster than realtime. Record 3–5 real nights once — via a debug-only full-night-recording flag that must be physically absent from release builds, since "never store full-night audio" is the headline privacy promise — hand-label the obvious bouts, then every detector/threshold change replays all nights in minutes with a report diff. This converts "sleep next to it for a week per tweak" into a CI-shaped regression suite. The companion debug **frame-CSV logger** (every `ClassifierFrame` to a file) feeds the Python reference model for offline threshold sweeps.

**Layer 4 — Acoustic soak rig + field matrix.** A speaker + phone on a desk overnight playing a scripted timeline (quiet → snoring segments → confounders: fan, white-noise machine, TV, conversation, dog, partner snoring, 7 a.m. alarm) with known ground truth; morning report compared against expectations with tolerances. This validates the mic-to-frame layer that Layers 1–3 bypass, without requiring sleep. Run it on the lifecycle matrix: locked screen all night, charging and unplugged, incoming call at 3 a.m., Low Power Mode/Battery Saver, Android mic toggle flip, permission revoke, storage nearly full, one aggressive-OEM Android device. Plus continuous developer dogfooding from M2 onward, and beta CSV collection in M8 to set the two per-platform `CONF_THRESHOLD` constants — deliberately the only detection numbers allowed to differ between platforms.

Conventional unit tests round it out per platform: migrations, ring-buffer wraparound, retention GC, recovery finalization, and the spec §5.1 debug assertion that recomputes rollups from rows and compares.

---

### Critical Files for Implementation
- spec/SHARED_BEHAVIOR_SPEC.md (v1.1 with the §0 reconciliations — the single source of truth, frozen in M0)
- spec/fixtures/detector/basic_bout.json (plus sibling fixtures — the cross-platform consistency mechanism)
- spec/schema/v1.sql (shared DDL copied verbatim into both apps)
- ios/Packages/SnoreCore/Sources/SnoreCore/SnoreDetector.swift (lead-platform pure detector; first real code after the spike)
- android/core/detection/src/main/kotlin/SnoreDetector.kt (port target; green on the same fixtures before any Android UI work)