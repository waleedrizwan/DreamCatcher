"""Dream Catcher — reference implementation of the shared detector.

This is the normative executable form of spec/SHARED_BEHAVIOR_SPEC.md §1.
It exists to (a) generate/validate the golden fixtures both native
implementations must pass, and (b) serve as the offline tuning tool for
threshold sweeps over recorded-night CSVs.

Pure Python 3, stdlib only. No wall clock, no I/O in the detector itself.
"""
from __future__ import annotations

import dataclasses
import json
from typing import List, Optional


@dataclasses.dataclass
class DetectorParams:
    WINDOW_MS: int = 1000
    HOP_MS: int = 500
    CONF_THRESHOLD: float = 0.35      # medium default; YAMNet sigmoid scale on both platforms
    CONF_STRONG: float = 0.55         # medium default; YAMNet sigmoid scale on both platforms
    SPEECH_VETO_CONF: float = 0.50
    NF_INIT: float = -60.0
    NF_RISE_PER_FRAME: float = 0.05
    NF_CLAMP_LO: float = -80.0
    NF_CLAMP_HI: float = -30.0
    GATE_OFFSET_DB: float = 12.0
    GATE_CLAMP_LO: float = -56.0
    GATE_CLAMP_HI: float = -38.0
    MERGE_GAP_MS: int = 30000
    MIN_EPISODE_EVENTS: int = 3
    MIN_EPISODE_SPAN_MS: int = 30000
    INTENSITY_LIGHT_MAX_DB: float = 25.0
    INTENSITY_MOD_MAX_DB: float = 40.0

    @classmethod
    def with_overrides(cls, overrides: dict) -> "DetectorParams":
        p = cls()
        for k, v in (overrides or {}).items():
            if not hasattr(p, k):
                raise KeyError(f"unknown param {k}")
            setattr(p, k, v)
        return p


@dataclasses.dataclass
class Frame:
    t_ms: int
    rms_dbfs: float
    peak_dbfs: float
    snore_conf: float
    speech_conf: float


@dataclasses.dataclass
class Event:
    start_ms: int
    end_ms: int = 0
    frame_count: int = 0
    peak_dbfs: float = -100.0
    max_conf: float = 0.0
    nf_at_start: float = 0.0
    last_frame_t_ms: int = 0


@dataclasses.dataclass
class Episode:
    id: int
    state: str  # PENDING | CONFIRMED
    events: List[Event]
    start_ms: int
    last_event_end_ms: int = 0
    # set at close:
    end_ms: int = 0
    snore_ms: int = 0
    peak: Optional[Event] = None
    bucket: str = ""


def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


class SnoreDetector:
    """Direct transliteration of spec §1.3. Keep in lockstep with
    ios/Packages/SnoreCore/.../SnoreDetector.swift and
    android/core/detection/.../SnoreDetector.kt."""

    def __init__(self, params: DetectorParams):
        self.p = params
        self.nf = params.NF_INIT
        self.cur_event: Optional[Event] = None
        self.episode: Optional[Episode] = None
        self._next_id = 1

    def process(self, f: Frame) -> List[dict]:
        p, out = self.p, []
        self.nf = clamp(min(f.rms_dbfs, self.nf + p.NF_RISE_PER_FRAME),
                        p.NF_CLAMP_LO, p.NF_CLAMP_HI)
        gate = clamp(self.nf + p.GATE_OFFSET_DB, p.GATE_CLAMP_LO, p.GATE_CLAMP_HI)
        vetoed = f.speech_conf >= p.SPEECH_VETO_CONF and f.speech_conf > f.snore_conf
        positive = (f.rms_dbfs >= gate and f.snore_conf >= p.CONF_THRESHOLD
                    and not vetoed)

        if positive:
            if self.cur_event is None:
                self.cur_event = Event(start_ms=f.t_ms, nf_at_start=self.nf)
            ev = self.cur_event
            ev.last_frame_t_ms = f.t_ms
            ev.frame_count += 1
            ev.peak_dbfs = max(ev.peak_dbfs, f.peak_dbfs)
            ev.max_conf = max(ev.max_conf, f.snore_conf)
        elif self.cur_event is not None:
            out += self._close_event()

        if (self.episode is not None and self.cur_event is None
                and f.t_ms - self.episode.last_event_end_ms > p.MERGE_GAP_MS):
            out += self._resolve_episode()
        return out

    def flush(self) -> List[dict]:
        out = []
        if self.cur_event is not None:
            out += self._close_event()
        if self.episode is not None:
            out += self._resolve_episode()
        return out

    def _close_event(self) -> List[dict]:
        p = self.p
        ev = self.cur_event
        self.cur_event = None
        ev.end_ms = ev.last_frame_t_ms + p.WINDOW_MS
        valid = ev.frame_count >= 2 or ev.max_conf >= p.CONF_STRONG
        if not valid:
            return []
        out = []
        if (self.episode is not None
                and ev.start_ms - self.episode.last_event_end_ms > p.MERGE_GAP_MS):
            out += self._resolve_episode()  # stale episode; close before attaching
        if self.episode is None:
            self.episode = Episode(id=self._next_id, state="PENDING", events=[],
                                   start_ms=ev.start_ms)
            self._next_id += 1
        epi = self.episode
        epi.events.append(ev)
        epi.last_event_end_ms = ev.end_ms
        out.append({"type": "EventDetected", "event": ev})
        if (epi.state == "PENDING"
                and len(epi.events) >= p.MIN_EPISODE_EVENTS
                and epi.last_event_end_ms - epi.start_ms >= p.MIN_EPISODE_SPAN_MS):
            epi.state = "CONFIRMED"
            out.append({"type": "EpisodeConfirmed", "episode": epi,
                        "confirmingEvent": ev})
        return out

    def _resolve_episode(self) -> List[dict]:
        epi = self.episode
        self.episode = None
        if epi.state == "CONFIRMED":
            epi.end_ms = epi.last_event_end_ms
            epi.snore_ms = sum(e.end_ms - e.start_ms for e in epi.events)
            # Normative tie-break: highest peakDbfs, EARLIEST event wins.
            peak = epi.events[0]
            for e in epi.events[1:]:
                if e.peak_dbfs > peak.peak_dbfs:
                    peak = e
            epi.peak = peak
            epi.bucket = self.intensity_bucket(peak)
            return [{"type": "EpisodeClosed", "episode": epi}]
        return [{"type": "EpisodeDiscarded", "episodeId": epi.id}]

    def intensity_bucket(self, peak: Event) -> str:
        rel = peak.peak_dbfs - peak.nf_at_start
        if rel < self.p.INTENSITY_LIGHT_MAX_DB:
            return "light"
        if rel < self.p.INTENSITY_MOD_MAX_DB:
            return "moderate"
        return "loud"


def replay_events(rows: List[dict], params: DetectorParams) -> dict:
    """Crash-recovery replay (spec §3.1): re-merge orphan event rows into
    episodes using the same merge/confirm rules. Deterministic; input rows
    sorted by start_ms. Row: {start_ms, end_ms, peak_dbfs, max_conf, nf_dbfs}."""
    episodes, discarded = [], 0
    group: List[dict] = []

    def resolve(g: List[dict]):
        nonlocal discarded
        if not g:
            return
        span = g[-1]["end_ms"] - g[0]["start_ms"]
        if len(g) >= params.MIN_EPISODE_EVENTS and span >= params.MIN_EPISODE_SPAN_MS:
            peak = g[0]
            for e in g[1:]:
                if e["peak_dbfs"] > peak["peak_dbfs"]:
                    peak = e
            rel = peak["peak_dbfs"] - peak["nf_dbfs"]
            bucket = ("light" if rel < params.INTENSITY_LIGHT_MAX_DB
                      else "moderate" if rel < params.INTENSITY_MOD_MAX_DB
                      else "loud")
            episodes.append({
                "startMs": g[0]["start_ms"], "endMs": g[-1]["end_ms"],
                "eventCount": len(g),
                "snoreMs": sum(e["end_ms"] - e["start_ms"] for e in g),
                "peakDbfs": peak["peak_dbfs"], "nfAtPeak": peak["nf_dbfs"],
                "bucket": bucket,
            })
        else:
            discarded += 1

    for row in sorted(rows, key=lambda r: r["start_ms"]):
        if group and row["start_ms"] - group[-1]["end_ms"] > params.MERGE_GAP_MS:
            resolve(group)
            group = []
        group.append(row)
    resolve(group)
    return {"episodes": episodes, "discardedEpisodes": discarded}


# ---------------------------------------------------------------------------
# Fixture running (shared by make_fixtures.py and any offline tuning script)

def episode_summary(epi: Episode) -> dict:
    return {
        "startMs": epi.start_ms, "endMs": epi.end_ms,
        "eventCount": len(epi.events), "snoreMs": epi.snore_ms,
        "peakDbfs": round(epi.peak.peak_dbfs, 4),
        "nfAtPeak": round(epi.peak.nf_at_start, 4),
        "bucket": epi.bucket,
    }


def run_fixture_frames(frames: List[list], flush_at_ms: List[int],
                       params: DetectorParams) -> dict:
    """Runner semantics (normative for all platforms):
    process frames in order; before processing a frame whose tMs is >= the
    next pending flushAtMs value, call flush() (consuming that value);
    after the last frame, consume remaining flush points and always flush
    once more for session end."""
    det = SnoreDetector(params)
    pending = sorted(flush_at_ms or [])
    events_detected = confirmed = 0
    episodes, discarded = [], 0

    def absorb(outputs):
        nonlocal events_detected, confirmed, discarded
        for o in outputs:
            if o["type"] == "EventDetected":
                events_detected += 1
            elif o["type"] == "EpisodeConfirmed":
                confirmed += 1
            elif o["type"] == "EpisodeClosed":
                episodes.append(episode_summary(o["episode"]))
            elif o["type"] == "EpisodeDiscarded":
                discarded += 1

    for row in frames:
        f = Frame(*row)
        while pending and f.t_ms >= pending[0]:
            pending.pop(0)
            absorb(det.flush())
        absorb(det.process(f))
    absorb(det.flush())  # session end
    return {"eventsDetected": events_detected, "confirmedEpisodes": confirmed,
            "episodes": episodes, "discardedEpisodes": discarded}


def run_fixture_file(path: str) -> dict:
    with open(path) as fh:
        fx = json.load(fh)
    params = DetectorParams.with_overrides(fx.get("params", {}))
    if "events" in fx:  # replay fixture
        rows = [{"start_ms": e[0], "end_ms": e[1], "peak_dbfs": e[2],
                 "max_conf": e[3], "nf_dbfs": e[4]} for e in fx["events"]]
        return replay_events(rows, params)
    return run_fixture_frames(fx["frames"], fx.get("flushAtMs", []), params)


if __name__ == "__main__":
    import sys
    for path in sys.argv[1:]:
        print(path, json.dumps(run_fixture_file(path), indent=2))
