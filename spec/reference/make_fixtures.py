"""Generate the golden detector fixtures in spec/fixtures/.

Each case is built as a frame sequence, run through the reference detector
(detector.py), asserted against the INTENT of the case (episode counts,
buckets, event counts), and only then written out with the reference run's
results as the `expect` block. If an intent assertion fails, the fixture is
wrong (or the detector is) — nothing gets written.

Frames are [tMs, rmsDbfs, peakDbfs, snoreConf, speechConf], 500 ms hops.
Synthetic fixtures use a t=0 anchor (real sessions use epoch ms; the
detector only cares about deltas).

Run:  python3 spec/reference/make_fixtures.py
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from detector import DetectorParams, run_fixture_frames, replay_events  # noqa: E402

HOP = 500
FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "..", "fixtures")

QUIET_RMS = -70.0


class Seq:
    """Frame-sequence builder with a running 500 ms cursor."""

    def __init__(self, t0: int = 0):
        self.t = t0
        self.frames: list[list] = []

    def emit(self, n: int, rms: float, peak: float, snore: float, speech: float = 0.0):
        for _ in range(n):
            self.frames.append([self.t, rms, peak, snore, speech])
            self.t += HOP
        return self

    def quiet(self, seconds: float, rms: float = QUIET_RMS):
        return self.emit(int(seconds * 1000) // HOP, rms, rms + 2.0, 0.0, 0.0)

    def skip_to(self, t_ms: int):
        assert t_ms >= self.t
        self.t = t_ms
        return self

    def bout(self, n_events: int, conf: float, rms: float = -38.0,
             peak0: float = -34.0, peak_step: float = -0.2,
             frames_per_event: int = 3, gap_s: float = 4.0,
             gap_rms: float = QUIET_RMS, speech: float = 0.0):
        """n events of frames_per_event positive frames, separated by gap_s of
        background. Event i peak = peak0 + i*peak_step (default: first loudest)."""
        for i in range(n_events):
            self.emit(frames_per_event, rms, peak0 + i * peak_step, conf, speech)
            if i < n_events - 1:
                self.quiet(gap_s, rms=gap_rms)
        return self


def write(name: str, sub: str, fx: dict):
    path = os.path.join(FIXTURE_DIR, sub, f"{name}.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(fx, fh, indent=1)
    print(f"wrote {sub}/{name}.json  frames={len(fx.get('frames', fx.get('events', [])))} "
          f"expect={json.dumps(fx['expect'])[:120]}")


def detector_fixture(name: str, seq: Seq, intent, params: dict | None = None,
                     flush_at: list[int] | None = None):
    result = run_fixture_frames(seq.frames, flush_at or [],
                                DetectorParams.with_overrides(params or {}))
    intent(result)  # raises if the case doesn't do what it claims
    fx = {"name": name, "params": params or {}, "frames": seq.frames,
          "flushAtMs": flush_at or [], "expect": result}
    write(name, "detector", fx)


def replay_fixture(name: str, events: list[list], intent, params: dict | None = None):
    rows = [{"start_ms": e[0], "end_ms": e[1], "peak_dbfs": e[2],
             "max_conf": e[3], "nf_dbfs": e[4]} for e in events]
    result = replay_events(rows, DetectorParams.with_overrides(params or {}))
    intent(result)
    fx = {"name": name, "params": params or {}, "events": events, "expect": result}
    write(name, "replay", fx)


def main():
    # 1. Steady bout confirms and closes; first event is loudest; moderate.
    s = Seq().quiet(5).bout(8, conf=0.9).quiet(40)
    def intent(r):
        assert r["eventsDetected"] == 8 and r["confirmedEpisodes"] == 1, r
        assert r["discardedEpisodes"] == 0 and len(r["episodes"]) == 1, r
        e = r["episodes"][0]
        assert e["eventCount"] == 8 and e["bucket"] == "moderate", e
        assert e["peakDbfs"] == -34.0, e  # earliest-max tie rule exercised later
    detector_fixture("basic_bout", s, intent)

    # 2. Two-event blip: valid events, episode never confirms, discarded.
    s = Seq().quiet(5).emit(2, -38, -34, 0.7).quiet(5).emit(2, -38, -34, 0.7).quiet(40)
    def intent(r):
        assert r["eventsDetected"] == 2 and r["discardedEpisodes"] == 1, r
        assert r["episodes"] == [] and r["confirmedEpisodes"] == 0, r
    detector_fixture("blip_discard", s, intent)

    # 3. Single strong-conf frame is a valid event; single weak frame is not.
    s = (Seq().quiet(5).emit(1, -38, -34, 0.85).quiet(10)
         .emit(1, -38, -34, 0.7).quiet(40))
    def intent(r):
        assert r["eventsDetected"] == 1 and r["discardedEpisodes"] == 1, r
        assert r["episodes"] == [], r
    detector_fixture("single_strong_frame", s, intent)

    # 4a. 29 s gap between two bouts merges into ONE episode.
    s = Seq().quiet(5).bout(7, conf=0.9).quiet(29).bout(7, conf=0.9).quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 1 and r["episodes"][0]["eventCount"] == 14, r
    detector_fixture("merge_gap_29s", s, intent)

    # 4b. 31 s gap splits into TWO episodes.
    s = Seq().quiet(5).bout(7, conf=0.9).quiet(31).bout(7, conf=0.9).quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 2, r
        assert all(e["eventCount"] == 7 for e in r["episodes"]), r
    detector_fixture("split_gap_31s", s, intent)

    # 5. Loud TV: high RMS, snoreConf above threshold, but speech veto wins.
    #    An implementation that ignores speechConf fails this fixture.
    s = Seq().quiet(5).emit(120, -30.0, -25.0, 0.65, speech=0.7).quiet(40)
    def intent(r):
        assert r["eventsDetected"] == 0 and r["episodes"] == [], r
        assert r["discardedEpisodes"] == 0, r
    detector_fixture("tv_speech_veto", s, intent)

    # 6. Quiet snorer over a fan: floor rises to the fan level, gate clamps at
    #    -38, snore at -35 still passes; relative intensity → light.
    s = (Seq().quiet(130, rms=-48.0)   # 260 frames: nf reaches -48 (creep 0.05/frame)
         .bout(7, conf=0.75, rms=-35.0, peak0=-30.0, gap_rms=-48.0)
         .quiet(40, rms=-48.0))
    def intent(r):
        assert len(r["episodes"]) == 1, r
        assert r["episodes"][0]["bucket"] == "light", r
    detector_fixture("quiet_snorer_fan", s, intent)

    # 7. Interruption flush lands mid-event: the open 2-frame event closes as
    #    valid, and the confirmed episode is force-closed by the flush.
    s = Seq().quiet(5).bout(7, conf=0.9).quiet(4)
    s.emit(2, -38, -33.0, 0.9)            # open event, 2 frames, then flush
    flush_at = [s.t + 300]
    last_event_end = (s.t - HOP) + 1000   # last positive frame + WINDOW_MS
    def intent(r):
        assert len(r["episodes"]) == 1 and r["episodes"][0]["eventCount"] == 8, r
        assert r["episodes"][0]["endMs"] == last_event_end, r
    detector_fixture("flush_straddle", s, intent, flush_at=flush_at)

    # 8. Interruption + 10 min gap + re-anchored resume: two episodes, second
    #    is loud (peak -25 over a -70 floor).
    s = Seq().quiet(5).bout(7, conf=0.9).quiet(5)
    flush_at = [s.t + 200]
    s.skip_to(s.t + 600_000)              # capture gap; service re-anchors
    s.quiet(5).bout(7, conf=0.9, rms=-30.0, peak0=-25.0).quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 2, r
        assert r["episodes"][0]["bucket"] == "moderate", r
        assert r["episodes"][1]["bucket"] == "loud", r
    detector_fixture("gap_resume", s, intent, flush_at=flush_at)

    # 9a. High sensitivity confirms a bout that Medium would miss (conf 0.5).
    s = Seq().quiet(5).bout(7, conf=0.5).quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 1, r
    detector_fixture("sensitivity_high", s, intent,
                     params={"CONF_THRESHOLD": 0.45, "CONF_STRONG": 0.70})

    # 9b. Low sensitivity rejects a bout that Medium would accept (conf 0.7).
    s = Seq().quiet(5).bout(7, conf=0.7).quiet(40)
    def intent(r):
        assert r["eventsDetected"] == 0 and r["episodes"] == [], r
    detector_fixture("sensitivity_low", s, intent,
                     params={"CONF_THRESHOLD": 0.75, "CONF_STRONG": 0.90})

    # 9c. Same conf-0.7 bout under Medium DOES confirm (companion to 9b).
    s = Seq().quiet(5).bout(7, conf=0.7).quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 1, r
    detector_fixture("sensitivity_medium_baseline", s, intent)

    # 10. Peak tie-break: two events share max peakDbfs; EARLIEST wins, and its
    #     (lower) noise floor decides the bucket. Guards Swift max(by:) footgun.
    s = Seq().quiet(5)
    s.bout(7, conf=0.9, peak0=-33.0, peak_step=0.0)  # all peaks equal
    s.quiet(40)
    def intent(r):
        assert len(r["episodes"]) == 1, r
        e = r["episodes"][0]
        # earliest event's nf is the lowest (floor creeps up during the bout)
        assert e["nfAtPeak"] <= -69.9, e
    detector_fixture("peak_tie_earliest", s, intent)

    # 11. Two-hour synthetic night: ambient ramps -75 → -45; the min-follower
    #     floor tracks it. A conf-0.3 loud burst early does nothing; a real bout
    #     mid-night (floor ≈ -60) is moderate; a -50 dBFS sound under a -47.5
    #     floor late in the night is correctly below the gate.
    s = Seq()
    total_frames = 14_400  # 2 h at 500 ms
    bout_at = 7_200        # frame index at t=3600 s
    late_at = 13_200       # frame index at t=6600 s
    i = 0
    def ambient(idx):
        return -75.0 + 30.0 * (idx / total_frames)
    while i < total_frames:
        if i == 1_200:  # t=600 s: loud but low-confidence burst
            s.emit(1, -20.0, -15.0, 0.3); i += 1
        elif i == bout_at:
            for k in range(7):  # bout: 3 frames + 8 ambient frames per event
                s.emit(3, -35.0, -30.0, 0.9); i += 3
                if k < 6:
                    a = ambient(i); s.emit(8, a, a + 2.0, 0.0); i += 8
        elif i == late_at:
            s.emit(20, -50.0, -45.0, 0.9); i += 20  # below gate under high floor
        else:
            a = ambient(i); s.emit(1, a, a + 2.0, 0.0); i += 1
    def intent(r):
        assert r["eventsDetected"] == 7, r["eventsDetected"]
        assert len(r["episodes"]) == 1 and r["episodes"][0]["bucket"] == "moderate", r
        assert r["discardedEpisodes"] == 0, r
    detector_fixture("nf_creep_2h", s, intent)

    # --- Recovery-replay fixtures (spec §3.1) --------------------------------
    # R1. Five orphan events over 40 s → one episode; a two-event straggler
    #     group a minute later is discarded.
    events = [[i * 10_000, i * 10_000 + 2_000, -33.0 - i, 0.9, -70.0] for i in range(5)]
    events += [[120_000, 122_000, -30.0, 0.9, -70.0],
               [128_000, 130_000, -30.0, 0.9, -70.0]]
    def intent(r):
        assert len(r["episodes"]) == 1 and r["discardedEpisodes"] == 1, r
        e = r["episodes"][0]
        assert e["eventCount"] == 5 and e["snoreMs"] == 10_000, e
        assert e["peakDbfs"] == -33.0 and e["bucket"] == "moderate", e
    replay_fixture("replay_basic", events, intent)

    # R2. Gaps of exactly 30 000 ms MERGE (split requires strictly greater).
    events = [[0, 2_000, -34.0, 0.9, -70.0],
              [32_000, 34_000, -33.0, 0.9, -70.0],
              [64_000, 66_000, -35.0, 0.9, -70.0]]
    def intent(r):
        assert len(r["episodes"]) == 1 and r["episodes"][0]["eventCount"] == 3, r
        assert r["episodes"][0]["peakDbfs"] == -33.0, r
    replay_fixture("replay_merge_boundary", events, intent)

    print("all fixture intents satisfied")


if __name__ == "__main__":
    main()
