#!/usr/bin/env python3
"""Dream Catcher — analyze one night recorded by the bedside Pi.

Reads the night's 10-minute WAV chunks (pulled by pull.sh), runs the same
YAMNet Core ML model the iPhone app bundles, feeds the frames through the
shared reference detector (spec/reference/detector.py), and writes:

    <data>/reports/<night>/report.html    the morning report
    <data>/reports/<night>/summary.json   machine-readable numbers
    <data>/reports/<night>/frames.csv     one row per 500 ms frame (levels + scores)
    <data>/reports/<night>/clips/*.wav    12 s per snoring episode, 8 s per gasp candidate

Frames follow spec §0 exactly as the iOS adapter builds them: a frame every
8 000 samples, rms/peak over the trailing 16 000 raw samples, YAMNet over the
trailing 15 600 samples peak-normalized to 0.5 (gain <= +30 dB), timestamps
from the sample count anchored at each capture (re)start (§0.2). A gap
between chunks (the recorder restarted) flushes the detector and re-anchors.

Usage:  pi/.venv/bin/python pi/analyze.py [NIGHT] [--data DIR] [--no-open]
        NIGHT is a folder name under <data>/nights (e.g. 2026-10-05) or a path;
        default is the most recent night.
"""
from __future__ import annotations

import argparse
import csv
import dataclasses
import datetime as dt
import html
import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "spec" / "reference"))
from detector import DetectorParams, Frame, SnoreDetector  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import denoise  # noqa: E402

MODEL_DIR = REPO / "ios/Packages/SnoreAudio/Sources/SnoreAudio/Resources"
TZ = ZoneInfo(os.environ.get("DC_TZ", "America/Toronto"))
DATA = Path(os.environ.get("DC_DATA", Path.home() / "DreamCatcher"))

SR = 16_000
HOP = 8_000            # spec HOP_MS = 500
WIN = 16_000           # spec WINDOW_MS = 1000, level window
CLS_WIN = 15_600       # one YAMNet patch, 0.975 s
NORM_PEAK, NORM_MAX_GAIN = 0.5, 31.6   # same as YAMNetClassifier.swift
CONTIGUOUS_TOLERANCE_MS = 2_000        # chunk boundaries closer than this are one capture

# Classes kept in frames.csv. Snoring and Speech drive the detector; the rest
# are exploratory (gasps now, labelling data for grinding later).
WATCH = ["Snoring", "Speech", "Gasp", "Snort", "Cough", "Breathing",
         "Throat clearing", "Chewing, mastication", "Biting"]

# Gasp candidates: YAMNet's Gasp class is uncalibrated for a bedside mic, so
# these surface moments worth listening to, ranked; they are not counted.
GASP_MIN_SCORE = 0.15
GASP_MIN_ABOVE_FLOOR_DB = 6.0
GASP_MERGE_MS = 5_000
GASP_MAX = 10

# Faint snoring: frames YAMNet scores as snoring that the detector could not
# count (too quiet relative to the mic's hiss). Grouped like the detector's
# merge gap and listed so the report never claims "no snoring" when the model
# plainly heard it.
FAINT_MIN_SCORE = 0.5
FAINT_MERGE_MS = 30_000
FAINT_MAX = 10

# AI-led counting (default on the Pi). The phone app's detector also requires
# each snore to be >= 12 dB above the room, which this USB mic's electrical hum
# makes impossible (adversarial review, 2026-10-05: snoring sits ~10 dB under
# the mic's own noise, yet YAMNet still recognises it and the user confirmed
# it by ear). Here a snore sound is a run of frames with snoring >= the shared
# CONF_THRESHOLD and no speech veto; sounds within MERGE_GAP_MS form a bout;
# a bout needs AI_MIN_SOUNDS sounds, so one isolated sound never counts.
AI_MIN_SOUNDS = 2

# Interactive report: each bout gets one clip covering the whole bout (plus a
# little either side), so clicking anywhere in it on the graph plays from
# exactly that moment.
BOUT_PAD_MS = 2_000
BOUT_CLIP_CAP = 200

CLIP_MS, CLIP_PREROLL_MS, CLIP_CAP = 12_000, 3_000, 30
GASP_CLIP_MS, GASP_PREROLL_MS = 8_000, 3_000
BIN_MS = 300_000


# --------------------------------------------------------------------------- audio files

@dataclasses.dataclass
class Chunk:
    path: Path
    wall_start_ms: int      # from the file name (recorder's clock at file open)
    data_offset: int
    n: int                  # samples
    seg_offset: int = 0     # sample index of this chunk's first sample within its segment


@dataclasses.dataclass
class Segment:
    """One uninterrupted capture: timestamps come from its sample count."""
    anchor_ms: int
    chunks: list[Chunk]

    @property
    def n(self) -> int:
        return sum(c.n for c in self.chunks)

    @property
    def end_ms(self) -> int:
        return self.anchor_ms + self.n * 1000 // SR

    def t_ms(self, sample_index: int) -> int:
        return self.anchor_ms + sample_index * 1000 // SR

    def read(self, s0: int, s1: int) -> np.ndarray:
        """int16 samples [s0, s1) of this segment, clamped to what exists."""
        s0, s1 = max(0, s0), min(self.n, s1)
        parts = []
        for c in self.chunks:
            a, b = max(s0, c.seg_offset), min(s1, c.seg_offset + c.n)
            if a < b:
                parts.append(pcm(c)[a - c.seg_offset:b - c.seg_offset])
        return np.concatenate(parts) if parts else np.zeros(0, np.int16)


def parse_wav(path: Path) -> tuple[int, int]:
    """(data offset, sample count). Ignores the header's size fields, which are
    wrong in a file cut short by a power loss; the file length is the truth."""
    head = path.read_bytes()[:4096]
    if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
        raise ValueError(f"{path.name}: not a WAV file")
    i, fmt = 12, None
    while i + 8 <= len(head):
        tag, size = head[i:i + 4], int.from_bytes(head[i + 4:i + 8], "little")
        if tag == b"fmt ":
            fmt = head[i + 8:i + 8 + 16]
        if tag == b"data":
            if fmt is None:
                raise ValueError(f"{path.name}: no fmt chunk")
            channels = int.from_bytes(fmt[2:4], "little")
            rate = int.from_bytes(fmt[4:8], "little")
            bits = int.from_bytes(fmt[14:16], "little")
            if (channels, rate, bits) != (1, SR, 16):
                raise ValueError(f"{path.name}: expected 16 kHz mono 16-bit, got "
                                 f"{rate} Hz {channels} ch {bits}-bit")
            offset = i + 8
            return offset, (path.stat().st_size - offset) // 2
        i += 8 + size + (size & 1)
    raise ValueError(f"{path.name}: no data chunk in the first 4 KB")


def pcm(c: Chunk) -> np.ndarray:
    return np.memmap(c.path, dtype="<i2", mode="r", offset=c.data_offset, shape=(c.n,))


def load_segments(night_dir: Path) -> list[Segment]:
    chunks = []
    for p in sorted(night_dir.glob("*.wav")):
        try:
            stamp = dt.datetime.strptime(p.stem, "%Y-%m-%d_%H-%M-%S").replace(tzinfo=TZ)
        except ValueError:
            print(f"  skipping {p.name}: name is not a recorder timestamp")
            continue
        offset, n = parse_wav(p)
        if n < WIN:
            print(f"  skipping {p.name}: shorter than one second")
            continue
        chunks.append(Chunk(p, int(stamp.timestamp() * 1000), offset, n))

    segments: list[Segment] = []
    for c in chunks:
        seg = segments[-1] if segments else None
        if seg and abs(c.wall_start_ms - seg.end_ms) <= CONTIGUOUS_TOLERANCE_MS:
            c.seg_offset = seg.n
            seg.chunks.append(c)
        else:
            segments.append(Segment(c.wall_start_ms, [c]))
    return segments


# --------------------------------------------------------------------------- model

class YAMNet:
    def __init__(self):
        import coremltools as ct
        names = []
        with open(MODEL_DIR / "yamnet_class_map.csv", newline="") as fh:
            for row in list(csv.reader(fh))[1:]:
                names.append(row[2])
        missing = [w for w in WATCH if w not in names]
        if missing:
            raise SystemExit(f"class map is missing {missing}; wrong model?")
        self.idx = [names.index(w) for w in WATCH]
        self.model = ct.models.CompiledMLModel(str(MODEL_DIR / "YAMNet.mlmodelc"),
                                               compute_units=ct.ComputeUnit.CPU_ONLY)

    def scores(self, windows: np.ndarray) -> np.ndarray:
        """windows: (k, 15600) float32 raw audio → (k, len(WATCH)) sigmoid scores."""
        peak = np.abs(windows).max(axis=1, keepdims=True)
        gain = np.where(peak > 0, np.minimum(NORM_PEAK / np.maximum(peak, 1e-12), NORM_MAX_GAIN), 1.0)
        x = np.clip(windows * gain, -1.0, 1.0).astype(np.float32)
        out = np.empty((len(x), len(WATCH)), np.float32)
        for b in range(0, len(x), 256):
            batch = [{"waveform": np.ascontiguousarray(row)} for row in x[b:b + 256]]
            for j, r in enumerate(self.model.predict(batch)):
                out[b + j] = r["scores"][0, self.idx]
        return out


def dbfs(x: np.ndarray) -> np.ndarray:
    with np.errstate(divide="ignore"):
        return np.clip(20 * np.log10(np.maximum(x, 0)), -100.0, 0.0)


def levels(windows: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    rms = dbfs(np.sqrt(np.mean(np.square(windows, dtype=np.float64), axis=1)))
    return rms, dbfs(np.abs(windows).max(axis=1))


def segment_frames(seg: Segment, model: YAMNet, clean_levels: bool, profiles: dict,
                   dehum: bool = True, tones: dict | None = None):
    """Yield (t_ms, rms, peak, raw_rms, scores[k, len(WATCH)]) per chunk, in order.

    YAMNet always sees raw audio (as on the phone). With clean_levels the
    detector's rms/peak are measured on hiss-removed audio instead, so faint
    snoring from a noisy mic can clear the loudness gate. Each chunk's hiss
    profile is stored in `profiles` for cleaning clips later."""
    tail = np.zeros(0, np.float32)
    ctail = np.zeros(0, np.float32)
    tail_start = 0                      # segment sample index of tail[0]
    for c in seg.chunks:
        new = pcm(c).astype(np.float32) / 32768.0
        if dehum:   # every steady tone (this file's + the night's) + 60 Hz family + sub-audio jumps
            if c.path not in tones:
                tones[c.path] = denoise.find_tones(new)
            new = denoise.remove_hum(new, tones=tones[c.path]).astype(np.float32)
        profiles[c.path] = denoise.noise_profile(new.astype(np.float64))
        buf = np.concatenate([tail, new])
        cbuf = (np.concatenate([ctail, denoise.denoise(new.astype(np.float64), profiles[c.path]).astype(np.float32)])
                if clean_levels else buf)
        pos_before, pos_after = c.seg_offset, c.seg_offset + c.n
        first = max(WIN, (pos_before // HOP + 1) * HOP)
        ends = np.arange(first, pos_after + 1, HOP)
        if len(ends):
            raw_rms, raw_peak = levels(sliding_window_view(buf, WIN)[ends - WIN - tail_start])
            rms, peak = (levels(sliding_window_view(cbuf, WIN)[ends - WIN - tail_start])
                         if clean_levels else (raw_rms, raw_peak))
            cls = sliding_window_view(buf, CLS_WIN)[ends - CLS_WIN - tail_start]
            t_ms = seg.anchor_ms + (ends - WIN) * 1000 // SR   # window START (spec §0)
            yield t_ms, rms, peak, raw_rms, model.scores(cls)
        keep = min(len(buf), WIN)
        tail, ctail, tail_start = buf[-keep:], cbuf[-keep:], pos_after - keep


# --------------------------------------------------------------------------- analysis

def analyze(night_dir: Path, out_dir: Path, clean_levels: bool = False,
            overrides: dict | None = None, mode: str = "ai", dehum: bool = True) -> dict:
    segments = load_segments(night_dir)
    if not segments:
        raise SystemExit(f"no recordings in {night_dir}")
    model = YAMNet()
    params = DetectorParams.with_overrides(overrides or {})
    profiles: dict = {}
    tones: dict = {}      # chunk path -> steady tones found in it (denoise.find_tones)
    det = SnoreDetector(params)
    episodes, discarded = [], 0
    rows = []          # frames.csv
    started = time.perf_counter()

    def absorb(outputs):
        nonlocal discarded
        for o in outputs:
            if o["type"] == "EpisodeClosed":
                episodes.append(o["episode"])
            elif o["type"] == "EpisodeDiscarded":
                discarded += 1

    if dehum:   # pass 1: steady tones per file, then add the night-wide ones to each file
        per_file = {c.path: denoise.find_tones(pcm(c)) for seg in segments for c in seg.chunks}
        common = denoise.night_tones(list(per_file.values()))
        tones.update({k: denoise.merge_tones(v, common) for k, v in per_file.items()})

    for si, seg in enumerate(segments):
        if si:
            absorb(det.flush())         # capture gap (spec §0.2): flush, re-anchor
        for t_ms, rms, peak, raw_rms, sc in segment_frames(seg, model, clean_levels, profiles, dehum, tones):
            for k in range(len(t_ms)):
                f = Frame(int(t_ms[k]), float(rms[k]), float(peak[k]),
                          float(sc[k, 0]), float(sc[k, 1]))
                absorb(det.process(f))
                gate = min(max(det.nf + params.GATE_OFFSET_DB, params.GATE_CLAMP_LO),
                           params.GATE_CLAMP_HI)
                rows.append((f.t_ms, f.rms_dbfs, f.peak_dbfs, det.nf, gate, si, float(raw_rms[k]), *sc[k]))
    absorb(det.flush())
    elapsed = time.perf_counter() - started

    session_start, session_end = segments[0].anchor_ms, segments[-1].end_ms
    gaps = [(a.end_ms, b.anchor_ms) for a, b in zip(segments, segments[1:])]
    events = [e for epi in episodes for e in epi.events]
    rel = lambda e: e.peak_dbfs - e.nf_at_start
    bucket = lambda e: ("light" if rel(e) < params.INTENSITY_LIGHT_MAX_DB
                        else "moderate" if rel(e) < params.INTENSITY_MOD_MAX_DB else "loud")
    snore_ms = sum(e.end_ms - e.start_ms for e in events)
    by_bucket = {b: sum(e.end_ms - e.start_ms for e in events if bucket(e) == b)
                 for b in ("light", "moderate", "loud")}

    out_dir.mkdir(parents=True, exist_ok=True)
    clip_dir = out_dir / "clips"
    clip_dir.mkdir(exist_ok=True)
    for old in clip_dir.glob("*.wav"):
        old.unlink()

    def seg_for(t: int) -> Segment:
        return next((s for s in segments if s.anchor_ms <= t < s.end_ms), segments[-1])

    def write_clip(name: str, t0: int, dur: int) -> str:
        """Writes the original and a hiss-removed, turned-up copy; returns the clean one."""
        seg = seg_for(t0 + CLIP_PREROLL_MS)
        s0 = (t0 - seg.anchor_ms) * SR // 1000
        audio = seg.read(s0, s0 + dur * SR // 1000)
        raw_name = name.replace(".wav", "_original.wav")
        with wave.open(str(clip_dir / raw_name), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes(audio.tobytes())
        # hiss profile of the chunk the clip starts in (measured over 10 minutes,
        # so a clip full of snoring is not mistaken for noise)
        chunk = next((c for c in seg.chunks if c.seg_offset <= max(0, s0) < c.seg_offset + c.n), seg.chunks[0])
        x = audio.astype(np.float64) / 32768
        clean = denoise.denoise(denoise.remove_hum(x, tones=tones.get(chunk.path)) if dehum else x,
                                profiles.get(chunk.path))
        denoise.write_wav(str(clip_dir / name), denoise.boost(clean))
        return f"clips/{name}"

    ep_out, faint, isolated = [], [], []
    if mode == "ai":
        bouts, isolated = detect_bouts(rows, params)
        counted_ms = sum(b["endMs"] - b["startMs"] for b in bouts)
        intervals = [(b["startMs"], b["endMs"], "snore") for b in bouts]
        sound_starts = [t for b in bouts for t in b["soundStarts"]]
        for i, b in enumerate(bouts):
            t0, clip = b["startMs"] - BOUT_PAD_MS, None
            if i < BOUT_CLIP_CAP:
                clip = write_clip(f"snore_{local(b['startMs'], '%H-%M-%S')}.wav", t0,
                                  b["endMs"] - b["startMs"] + 2 * BOUT_PAD_MS)
            ep_out.append({**b, "clip": clip, "clipStartMs": t0})
    else:
        counted_ms = snore_ms
        intervals = [(ev.start_ms, ev.end_ms, bucket(ev)) for ev in events]
        sound_starts = [ev.start_ms for ev in events]
        for i, epi in enumerate(episodes):
            t0, clip = epi.start_ms - BOUT_PAD_MS, None
            if i < BOUT_CLIP_CAP:
                clip = write_clip(f"snore_{local(epi.start_ms, '%H-%M-%S')}.wav", t0,
                                  epi.end_ms - epi.start_ms + 2 * BOUT_PAD_MS)
            ep_out.append({
                "startMs": epi.start_ms, "endMs": epi.end_ms, "events": len(epi.events),
                "sounds": len(epi.events), "peakMs": epi.peak.start_ms, "clipStartMs": t0,
                "snoreMs": epi.snore_ms, "bucket": epi.bucket,
                "aboveRoomDb": round(rel(epi.peak), 1), "peakDbfs": round(epi.peak.peak_dbfs, 1),
                "clip": clip,
            })
        faint = find_faint(rows, episodes)
        for fb in faint:
            fb["clip"] = (write_clip(f"faint_{local(fb['startMs'], '%H-%M-%S')}.wav",
                                     fb["startMs"] - CLIP_PREROLL_MS, CLIP_MS)
                          if fb.pop("withClip") else None)

    gasps = find_gasps(rows)
    for g in gasps:
        t0 = g["tMs"] - GASP_PREROLL_MS
        g["clip"] = write_clip(f"gasp_{local(g['tMs'], '%H-%M-%S')}.wav", t0, GASP_CLIP_MS)
        g["clipStartMs"] = t0

    with open(out_dir / "frames.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["t_ms", "local_time", "rms_dbfs", "peak_dbfs", "noise_floor_dbfs",
                    "gate_dbfs", "segment", "raw_rms_dbfs",
                    *[n.split(",")[0].lower().replace(" ", "_") for n in WATCH]])
        for r in rows:
            w.writerow([r[0], local(r[0], "%H:%M:%S.%f")[:-5], *(f"{v:.2f}" for v in r[1:5]),
                        r[5], f"{r[6]:.2f}", *(f"{v:.4f}" for v in r[7:])])

    summary = {
        "night": night_of(session_start),
        "source": str(night_dir),
        "startMs": session_start, "endMs": session_end,
        "recordedMs": sum(s.n for s in segments) * 1000 // SR,
        "gaps": [{"fromMs": a, "toMs": b} for a, b in gaps],
        "mode": mode,
        "snoreMs": counted_ms,
        "percentOfNight": round(100 * counted_ms / max(1, session_end - session_start)),
        "episodes": ep_out, "discardedEpisodes": discarded,
        "isolatedSounds": isolated,
        "intensityMs": by_bucket if mode == "spec" else None,
        # what the phone app's stricter rules would have counted, for comparison
        "strictDetector": {"snoreMs": snore_ms, "episodes": len(episodes)},
        "roomLevelDbfs": round(float(np.median([e.nf_at_start for e in events])), 1) if events else None,
        "medianFrameDbfs": round(float(np.median([r[1] for r in rows])), 1),
        "gaspCandidates": gasps,
        "faintSnoring": faint,
        # each frame is a 1 s window on a 0.5 s hop, so frames x 0.5 s ≈ time heard
        "faintSnoreMs": sum(fb["frames"] for fb in faint) * 500,
        "frames": len(rows), "analysisSeconds": round(elapsed, 1),
        "model": "YAMNet Core ML (ios bundle), CPU", "detectorParams": dataclasses.asdict(params),
        "levelsFrom": "hiss-removed audio" if clean_levels else "raw audio",
        "humRemoved": dehum,
        "tonesRemovedPerFile": {Path(k).name: [round(t, 2) for t in v[:12]] for k, v in tones.items()},
        "timeline": timeline(session_start, session_end, intervals),
        # counted snore sounds starting in each minute of the night (the line graph)
        "snoresPerMinute": np.bincount(
            [(t - session_start) // 60_000 for t in sound_starts if session_start <= t < session_end],
            minlength=-(-(session_end - session_start) // 60_000)).tolist(),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    (out_dir / "report.html").write_text(render(summary))
    return summary


def find_gasps(rows) -> list[dict]:
    gi = 7 + WATCH.index("Gasp")
    hits = [(r[0], r[gi]) for r in rows if r[gi] >= GASP_MIN_SCORE and r[1] >= r[3] + GASP_MIN_ABOVE_FLOOR_DB]
    groups: list[list] = []
    for t, s in hits:
        if groups and t - groups[-1][-1][0] <= GASP_MERGE_MS:
            groups[-1].append((t, s))
        else:
            groups.append([(t, s)])
    best = sorted((max(g, key=lambda x: x[1]) for g in groups), key=lambda x: -x[1])[:GASP_MAX]
    return [{"tMs": int(t), "score": round(float(s), 2)} for t, s in sorted(best)]


def find_faint(rows, episodes) -> list[dict]:
    si = 7 + WATCH.index("Snoring")
    counted = [(e.start_ms, e.end_ms) for e in episodes]
    hits = [(r[0], r[si]) for r in rows if r[si] >= FAINT_MIN_SCORE
            and not any(a <= r[0] < b for a, b in counted)]
    groups: list[list] = []
    for t, sc in hits:
        if groups and t - groups[-1][-1][0] <= FAINT_MERGE_MS:
            groups[-1].append((t, sc))
        else:
            groups.append([(t, sc)])
    longest = {id(g) for g in sorted(groups, key=len, reverse=True)[:FAINT_MAX]}
    return [{"startMs": int(g[0][0]), "endMs": int(g[-1][0]) + 1000, "frames": len(g),
             "maxScore": round(float(max(x[1] for x in g)), 2), "withClip": id(g) in longest}
            for g in groups]


def timeline(start: int, end: int, intervals) -> list[dict]:
    """intervals: (start_ms, end_ms, bucket) — bucket is light/moderate/loud, or "snore" in AI mode."""
    rank = {"snore": 1, "light": 1, "moderate": 2, "loud": 3}
    bins = []
    for b0 in range(start, end, BIN_MS):
        b1 = min(b0 + BIN_MS, end)
        secs, worst = 0, None
        for a, b, bk in intervals:
            ov = min(b1, b) - max(b0, a)
            if ov > 0:
                secs += ov
                if worst is None or rank[bk] > rank[worst]:
                    worst = bk
        bins.append({"startMs": b0, "endMs": b1, "snoreSec": round(secs / 1000), "bucket": worst})
    return bins


def detect_bouts(rows, params) -> tuple[list[dict], list[dict]]:
    """AI-led counting; see AI_MIN_SOUNDS. Returns (bouts, isolated sounds)."""
    si, spi = 7 + WATCH.index("Snoring"), 7 + WATCH.index("Speech")
    events, last = [], None          # [start_ms, end_ms, max_score, t_of_max]
    for r in rows:
        t, sc, sp = r[0], float(r[si]), float(r[spi])
        if sc < params.CONF_THRESHOLD or (sp >= params.SPEECH_VETO_CONF and sp > sc):
            continue
        if last is not None and t - last == params.HOP_MS:
            ev = events[-1]
            ev[1] = t + params.WINDOW_MS
            if sc > ev[2]:
                ev[2], ev[3] = sc, t
        else:
            events.append([t, t + params.WINDOW_MS, sc, t])
        last = t
    groups: list[list] = []
    for ev in events:
        if groups and ev[0] - groups[-1][-1][1] <= params.MERGE_GAP_MS:
            groups[-1].append(ev)
        else:
            groups.append([ev])
    bouts, isolated = [], []
    for g in groups:
        top = max(g, key=lambda ev: ev[2])
        if len(g) >= AI_MIN_SOUNDS:
            bouts.append({"startMs": int(g[0][0]), "endMs": int(g[-1][1]), "sounds": len(g),
                          "soundStarts": [int(ev[0]) for ev in g],
                          "soundMs": int(sum(ev[1] - ev[0] for ev in g)),
                          "maxScore": round(top[2], 2), "peakMs": int(top[3])})
        else:
            isolated.append({"tMs": int(top[3]), "score": round(top[2], 2)})
    return bouts, isolated


# --------------------------------------------------------------------------- report

def local(ms: int, fmt: str) -> str:
    return dt.datetime.fromtimestamp(ms / 1000, TZ).strftime(fmt)


def night_of(ms: int) -> str:   # spec §3.1: local date of (start − 12 h)
    return dt.datetime.fromtimestamp(ms / 1000 - 12 * 3600, TZ).strftime("%Y-%m-%d")


def hm(ms: int) -> str:
    if ms < 60_000:
        return f"{round(ms / 1000)} s"
    if ms < 600_000:
        sec = round(ms / 1000)
        return f"{sec // 60} m {sec % 60:02d} s"
    m = round(ms / 60000)
    return f"{m // 60} h {m % 60:02d} m" if m >= 60 else f"{m} m"


def render(s: dict) -> str:
    e = html.escape
    start, end = s["startMs"], s["endMs"]
    span = max(1, end - start)
    night = dt.date.fromisoformat(s["night"])
    W, H = 1000, 120

    def x(t):
        return (t - start) / span * W

    def pct(t):
        return f"{(t - start) / span * 100:.2f}%"

    ai = s.get("mode") == "ai"
    bouts = s["episodes"]
    per_min = s.get("snoresPerMinute") or []
    ymax = max(4, max(per_min, default=0))

    # The chart lives in a stretched SVG (x follows the screen width, height is
    # fixed); labels, markers, cursor and playhead are HTML positioned by
    # percent so they keep their size on a phone.
    svg = [f'<svg class="chart" viewBox="0 0 {W} {H}" preserveAspectRatio="none" role="img" '
           f'aria-label="Snores per minute across the night">']
    for g in s["gaps"]:
        svg.append(f'<rect class="gap" x="{x(g["fromMs"]):.1f}" y="0" width="{max(2, x(g["toMs"]) - x(g["fromMs"])):.1f}" height="{H}"></rect>')
    for i, b in enumerate(bouts):
        svg.append(f'<rect class="band" data-i="{i}" x="{x(b["startMs"]):.2f}" y="0" width="{max(1.2, x(b["endMs"]) - x(b["startMs"])):.2f}" height="{H}"></rect>')
    if per_min:
        pts = [(x(start + (m + 0.5) * 60_000), H - 2 - c / ymax * (H - 10)) for m, c in enumerate(per_min)]
        line = "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in pts)
        svg.append(f'<path class="areafill" d="{line} L{pts[-1][0]:.1f},{H} L{pts[0][0]:.1f},{H} Z"/>')
        svg.append(f'<path class="line" d="{line}"/>')
    svg.append(f'<line class="axis" x1="0" y1="{H}" x2="{W}" y2="{H}" vector-effect="non-scaling-stroke"/>')
    svg.append("</svg>")

    marks = "".join(
        f'<button class="mark" data-gasp="{i}" style="left:{pct(g["tMs"])}" title="Possible gasp {local(g["tMs"], "%-I:%M:%S %p").lower()} (score {g["score"]}): click to listen">▼</button>'
        for i, g in enumerate(s["gaspCandidates"]))
    ticks = []
    hour = dt.datetime.fromtimestamp(start / 1000, TZ).replace(minute=0, second=0, microsecond=0)
    while hour.timestamp() * 1000 <= end:
        t = int(hour.timestamp() * 1000)
        if t >= start:
            frac = (t - start) / span
            align = "edge-l" if frac < 0.03 else "edge-r" if frac > 0.97 else ""
            ticks.append(f'<span class="tlabel {align}" style="left:{pct(t)}">{hour.strftime("%-I %p").lower()}</span>')
        hour += dt.timedelta(hours=1)
    strip_items = ([(fb["startMs"], fb["endMs"], "Faint snoring") for fb in s.get("faintSnoring", [])]
                   + [(i["tMs"], i["tMs"] + 1000, "Single snore sound") for i in s.get("isolatedSounds", [])])
    strip = ""
    if strip_items:
        strip = (f'<svg class="strip" viewBox="0 0 {W} 10" preserveAspectRatio="none" aria-label="Not counted">'
                 + "".join(f'<rect class="faint" x="{x(a):.1f}" y="0" width="{max(3.0, x(b) - x(a)):.1f}" height="10"><title>{label} {local(a, "%-I:%M %p").lower()}</title></rect>'
                           for a, b, label in strip_items) + "</svg>")
    timeline_html = (
        f'<div class="tl{" quiet" if not bouts else ""}"><div class="marks">{marks}</div>'
        f'<div class="chartwrap" id="chartarea"><span class="ymax">{ymax} snores/min</span>{"".join(svg)}'
        '<div class="cursor" id="cursor" hidden></div><div class="playhead" id="playhead" hidden></div>'
        '<div class="tip" id="tip" hidden></div></div>'
        f'{strip}<div class="ticks">{"".join(ticks)}</div></div>')
    js_data = json.dumps({
        "start": start, "end": end, "tz": str(TZ), "perMin": per_min,
        "bouts": [{"i": i, "startMs": b["startMs"], "endMs": b["endMs"], "peakMs": b["peakMs"],
                   "clip": b["clip"], "clipStartMs": b["clipStartMs"], "sounds": b["sounds"]}
                  for i, b in enumerate(bouts)],
        "gasps": [{"tMs": g["tMs"], "clip": g["clip"], "clipStartMs": g["clipStartMs"]}
                  for g in s["gaspCandidates"]],
    })

    total = max(1, s["snoreMs"])
    im = s.get("intensityMs") or {}
    inten = "".join(
        f'<div class="seg {b}" style="flex:{im[b]}" title="{b}: {hm(im[b])}"></div>'
        for b in ("light", "moderate", "loud") if im.get(b))
    inten_legend = " · ".join(
        f'<span class="dot {b}"></span>{b} {round(100 * im[b] / total)}% ({hm(im[b])})'
        for b in ("light", "moderate", "loud")) if im else ""

    ep_rows = ""
    for i, ep in enumerate(s["episodes"]):
        player = (f'<button class="play" data-bout="{i}">▶ Listen</button> '
                  f'<a class="orig" href="{e(ep["clip"].replace(".wav", "_original.wav"))}">original</a>'
                  if ep["clip"] else "—")
        if ai:
            ep_rows += (
                f'<tr><td>{local(ep["startMs"], "%-I:%M %p").lower()}</td><td>{hm(ep["endMs"] - ep["startMs"])}</td>'
                f'<td>{ep["sounds"]}</td><td>{player}</td></tr>')
        else:
            ep_rows += (
                f'<tr><td>{local(ep["startMs"], "%-I:%M %p").lower()}</td><td>{hm(ep["endMs"] - ep["startMs"])}</td>'
                f'<td>{hm(ep["snoreMs"])}</td><td><span class="chip {ep["bucket"]}">{ep["bucket"]}</span></td>'
                f'<td>+{ep["aboveRoomDb"]:.0f} dB</td><td>{player}</td></tr>')
    gasp_rows = "".join(
        f'<tr><td>{local(g["tMs"], "%-I:%M:%S %p").lower()}</td><td>{g["score"]:.2f}</td>'
        f'<td><button class="play" data-gasp="{i}">▶ Listen</button> '
        f'<a class="orig" href="{e(g["clip"].replace(".wav", "_original.wav"))}">original</a></td></tr>'
        for i, g in enumerate(s["gaspCandidates"]))

    faint_ms = s.get("faintSnoreMs", 0)
    faint_n = len(s.get("faintSnoring", []))
    longest = max((ep["endMs"] - ep["startMs"] for ep in s["episodes"]), default=0)
    stats = [
        (hm(s["snoreMs"]) if s["snoreMs"] else "0 m", "snoring"),
        (f'{s["percentOfNight"]}%', "of the night"),
        (str(len(s["episodes"])), "snoring bout" + ("" if len(s["episodes"]) == 1 else "s")),
        (hm(longest) if longest else "—", "longest bout"),
    ] if ai else [
        (hm(s["snoreMs"]) if s["snoreMs"] else "0 m", "snoring counted" if faint_ms else "snoring"),
        *([(f"~{hm(faint_ms)}", f"faint snoring heard, {faint_n} stretch{'es' if faint_n != 1 else ''}")] if faint_ms else []),
        (f'{s["percentOfNight"]}%', "of the night"),
        (str(len(s["episodes"])), "episode" + ("" if len(s["episodes"]) == 1 else "s")),
        (f'{round(s["roomLevelDbfs"] if s["roomLevelDbfs"] is not None else s["medianFrameDbfs"])} dBFS', "room level"),
    ]
    banner = ""
    if s["gaps"]:
        banner = f'<p class="banner">Recording paused {len(s["gaps"])} time{"s" if len(s["gaps"]) > 1 else ""} (gray on the timeline).</p>'

    n_iso = len(s.get("isolatedSounds", []))
    ai_note = ('<p class="note">A bout runs from the first to the last snore the AI heard, with no gap longer than 30 s. '
               'This microphone is too quiet to measure how loud each snore was, so bouts are counted by the AI alone'
               f'{f" and {n_iso} single isolated snore sound" + ("s" if n_iso != 1 else "") + " (purple on the timeline) were left out" if n_iso else ""}.</p>')
    body_eps = (ai_note + f'<table><thead><tr><th>Started</th><th>Lasted</th><th>Snore sounds</th><th>Listen</th></tr></thead><tbody>{ep_rows}</tbody></table>'
                if ai and s["episodes"] else
                f'<table><thead><tr><th>Started</th><th>Lasted</th><th>Snoring</th><th>Intensity</th><th>Above room</th><th>Listen</th></tr></thead><tbody>{ep_rows}</tbody></table>'
                if s["episodes"] else ('<p class="empty">No snoring loud enough to count. The model did hear some; see "Snoring too faint to count" below.</p>'
                                       if s.get("faintSnoring") else '<p class="empty">No snoring detected.</p>'))
    faint_rows = "".join(
        f'<tr><td>{local(fb["startMs"], "%-I:%M %p").lower()}</td><td>{hm(fb["endMs"] - fb["startMs"])}</td>'
        f'<td>{fb["frames"]}</td><td><audio controls preload="none" src="{e(fb["clip"])}"></audio> '
        f'<a class="orig" href="{e(fb["clip"].replace(".wav", "_original.wav"))}">original</a></td></tr>'
        for fb in s.get("faintSnoring", []) if fb["clip"])
    shown = sum(1 for fb in s.get("faintSnoring", []) if fb["clip"])
    body_faint = (
        f'<p class="note">The model recognised snoring {faint_n} time{"s" if faint_n != 1 else ""} (purple on the timeline), but it was barely louder than the microphone\'s own hiss, '
        f'so it is not in the counted total. {"Showing the " + str(shown) + " longest. " if shown < faint_n else ""}A better microphone turns these into counted snoring.</p>'
        f'<table><thead><tr><th>Started</th><th>Span</th><th>Snore moments</th><th>Listen</th></tr></thead><tbody>{faint_rows}</tbody></table>'
        if s.get("faintSnoring") else "")
    body_gasp = (f'<p class="note">YAMNet flagged these as gasp-like. It has not been tuned on your room yet, so listen before trusting them; your labels will tune it.</p>'
                 f'<table><thead><tr><th>Time</th><th>Score</th><th>Listen</th></tr></thead><tbody>{gasp_rows}</tbody></table>'
                 if s["gaspCandidates"] else '<p class="empty">No gasp-like sounds stood out.</p>')

    legend = ([("var(--moderate)", "snoring")] if ai else
              [("var(--light)", "light"), ("var(--moderate)", "moderate"), ("var(--loud)", "loud")])
    if strip_items:
        legend.append(("var(--faint)", "single snore sound (not counted)" if ai else "faint snoring (not counted)"))
    legend += [("var(--gasp)", "possible gasp"), ("var(--gap)", "not recording")]
    legend_html = "".join(f'<span><span class="dot" style="background:{c}"></span>{e(t)}</span>' for c, t in legend)
    strict = s.get("strictDetector", {})
    footer_detail = (f'Counted by the AI (snoring score ≥ {s["detectorParams"]["CONF_THRESHOLD"]}, speech filtered out, at least {AI_MIN_SOUNDS} snores per bout). '
                     f'The phone app\'s stricter loudness rules would have counted {hm(strict.get("snoreMs", 0)) if strict.get("snoreMs") else "nothing"}.'
                     if ai else
                     f'Shared detector (Medium sensitivity), loudness measured on {e(s["levelsFrom"])}. '
                     f'{s["discardedEpisodes"]} short bout{"s" if s["discardedEpisodes"] != 1 else ""} too brief to count.')
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dream Catcher · {night.strftime('%b %-d')}</title>
<style>
:root {{ --bg:#fbfaf8; --card:#fff; --ink:#1d1d1f; --muted:#6e6e73; --line:#e6e4df;
  --light:#f3cd8f; --moderate:#e5812e; --loud:#9e2a14; --gap:#d9d7d2; --gasp:#3a6fd8; --faint:#9b8fc4; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#141416; --card:#1d1d20; --ink:#f2f2f4; --muted:#9a9aa0;
  --line:#2e2e33; --light:#7a6240; --moderate:#d9782a; --loud:#ff4d3d; --gap:#3a3a40; --gasp:#7aa2ff; --faint:#8f84c0; }} }}
* {{ box-sizing:border-box }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }}
main {{ max-width:960px; margin:0 auto; padding:32px 16px 64px; }}
h1 {{ font-size:28px; margin:0; letter-spacing:-0.01em }}
h2 {{ font-size:17px; margin:0 0 12px }}
.sub {{ color:var(--muted); margin:4px 0 24px }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:14px; padding:20px; margin-bottom:16px }}
.stats {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:16px }}
.stat {{ background:var(--card); border:1px solid var(--line); border-radius:14px; padding:16px 18px }}
.stat b {{ display:block; font-size:26px; font-variant-numeric:tabular-nums; letter-spacing:-0.01em }}
.stat span {{ color:var(--muted); font-size:13px }}
.tl {{ position:relative }}
.tl svg {{ width:100%; height:130px; display:block }}
.marks {{ position:relative; height:18px }}
.mark {{ position:absolute; top:0; transform:translateX(-50%); color:var(--gasp); font-size:12px; line-height:1;
  background:none; border:0; padding:0 2px; cursor:pointer }}
[hidden] {{ display:none !important }}
.chartwrap {{ position:relative; cursor:pointer }}
.tl svg.chart {{ height:140px }}
.tl.quiet svg.chart {{ height:40px }}
.line {{ fill:none; stroke:var(--moderate); stroke-width:1.75; vector-effect:non-scaling-stroke; stroke-linejoin:round }}
.areafill {{ fill:var(--moderate); opacity:.14 }}
.band {{ fill:var(--moderate); opacity:.08 }} .band.on {{ opacity:.25 }}
.cursor, .playhead {{ position:absolute; top:0; bottom:0; width:1px; pointer-events:none }}
.cursor {{ background:var(--muted); opacity:.6 }}
.playhead {{ background:var(--ink); width:2px; margin-left:-1px }}
.tip {{ position:absolute; top:6px; transform:translateX(-50%); background:var(--ink); color:var(--bg); font-size:12px;
  padding:3px 8px; border-radius:6px; white-space:nowrap; pointer-events:none }}
.ymax {{ position:absolute; left:0; top:0; font-size:11px; color:var(--muted); pointer-events:none }}
.play {{ font:inherit; font-size:13px; border:1px solid var(--line); background:var(--bg); color:var(--ink);
  border-radius:999px; padding:3px 12px; cursor:pointer }}
.play.on {{ background:var(--moderate); color:#fff; border-color:transparent }}
.pbar {{ position:sticky; bottom:12px; margin-top:16px; background:var(--card); border:1px solid var(--line);
  border-radius:14px; padding:10px 14px; display:flex; gap:12px; align-items:center;
  box-shadow:0 8px 28px rgba(0,0,0,.14); z-index:5 }}
.pbar audio {{ flex:1; max-width:none; min-width:0 }}
#now {{ font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:45% }}
.ticks {{ position:relative; height:20px; margin-top:4px }}
.tlabel {{ position:absolute; top:0; transform:translateX(-50%); color:var(--muted); font-size:12px; white-space:nowrap }}
.tlabel.edge-l {{ transform:none }} .tlabel.edge-r {{ transform:translateX(-100%) }}
.bar.snore {{ fill:var(--moderate) }}
.bar.light {{ fill:var(--light) }} .bar.moderate {{ fill:var(--moderate) }} .bar.loud {{ fill:var(--loud) }}
.gap {{ fill:var(--gap); opacity:.7 }}
.tl svg.strip {{ height:10px; margin-top:4px }}
.tl.quiet svg:not(.strip) {{ height:8px }}
.faint {{ fill:var(--faint) }}
.axis {{ stroke:var(--line); stroke-width:1 }}
.inten {{ display:flex; height:12px; border-radius:6px; overflow:hidden; gap:2px; margin-bottom:8px }}
.seg.light, .dot.light, .chip.light {{ background:var(--light) }}
.seg.moderate, .dot.moderate, .chip.moderate {{ background:var(--moderate) }}
.seg.loud, .dot.loud, .chip.loud {{ background:var(--loud) }}
.dot {{ display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:5px }}
.legend {{ color:var(--muted); font-size:13px }}
.chip {{ color:#fff; border-radius:999px; padding:1px 9px; font-size:12px }}
.chip.light {{ color:#3b2410 }}
@media (prefers-color-scheme: dark) {{ .chip.light {{ color:#fff }} }}
table {{ width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums }}
th {{ text-align:left; color:var(--muted); font-weight:500; font-size:13px; padding:6px 8px; border-bottom:1px solid var(--line) }}
td {{ padding:8px; border-bottom:1px solid var(--line); vertical-align:middle; white-space:nowrap }}
tr:last-child td {{ border-bottom:0 }}
audio {{ height:32px; max-width:260px }}
.empty, .note {{ color:var(--muted); margin:0 }}
.orig {{ color:var(--muted); font-size:12px; margin-left:6px }}
.note {{ margin-bottom:12px; font-size:13px }}
.banner {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px 14px; color:var(--muted) }}
.legend-row {{ display:flex; gap:16px; flex-wrap:wrap; margin-top:10px }}
footer {{ color:var(--muted); font-size:12px; margin-top:24px }}
@media (max-width:640px) {{ .wide {{ overflow-x:auto }} audio {{ max-width:180px }} }}
</style></head><body><main>
<h1>Night of {night.strftime('%A, %B %-d')}</h1>
<p class="sub">{local(start, '%-I:%M %p').lower()} – {local(end, '%-I:%M %p').lower()} · {hm(s["recordedMs"])} recorded</p>
{banner}
<div class="stats">{"".join(f'<div class="stat"><b>{e(v)}</b><span>{e(k)}</span></div>' for v, k in stats)}</div>
<section class="card"><h2>Timeline</h2><p class="note">Snores per minute through the night; shaded areas are snoring bouts. Click anywhere on the graph to hear that moment.</p>{timeline_html}
<div class="legend legend-row">{legend_html}</div></section>
{f'<section class="card"><h2>Intensity</h2><div class="inten">{inten}</div><div class="legend">{inten_legend}</div></section>' if s["snoreMs"] and im else ""}
<section class="card wide"><h2>{"Snoring bouts" if ai else "Snoring episodes"}</h2>{body_eps}</section>
{f'<section class="card wide"><h2>Snoring too faint to count</h2>{body_faint}</section>' if body_faint else ""}
<section class="card wide"><h2>Possible gasps</h2>{body_gasp}</section>
<div class="pbar" id="pbar" hidden><span id="now"></span><audio id="player" controls preload="none"></audio></div>
<footer>Dream Catcher can't tell who, or what, is snoring. Analyzed {s["frames"]:,} frames in {s["analysisSeconds"]} s with {e(s["model"])}. {footer_detail} Clips have the mic hiss removed and are turned up; "original" is the untouched recording.</footer>
</main>
<script id="dc-data" type="application/json">{js_data}</script>
<script>{PLAYER_JS}</script>
</body></html>"""


PLAYER_JS = "\n(() => {\n  const D = JSON.parse(document.getElementById('dc-data').textContent);\n  const area = document.getElementById('chartarea');\n  const player = document.getElementById('player'), bar = document.getElementById('pbar'), now = document.getElementById('now');\n  const cursor = document.getElementById('cursor'), head = document.getElementById('playhead'), tip = document.getElementById('tip');\n  const span = D.end - D.start;\n  const pct = t => ((t - D.start) / span * 100) + '%';\n  const fmt = (t, sec) => new Date(t).toLocaleTimeString('en-US',\n    {hour: 'numeric', minute: '2-digit', second: sec ? '2-digit' : undefined, timeZone: D.tz}).toLowerCase();\n  const timeAt = ev => { const r = area.getBoundingClientRect();\n    return D.start + Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width)) * span; };\n  const boutAt = t => D.bouts.find(b => b.clip && t >= b.startMs - 5000 && t <= b.endMs + 5000);\n  const nearest = t => { let best = null, bd = Infinity;\n    for (const b of D.bouts) { if (!b.clip) continue;\n      const d = Math.max(b.startMs - t, t - b.endMs, 0); if (d < bd) { bd = d; best = b; } }\n    return bd <= 15 * 60000 ? best : null; };\n  let current = null;\n  function play(item, t, label, isBout) {\n    current = item;\n    const off = Math.max(0, (t - item.clipStartMs) / 1000);\n    const go = () => { player.currentTime = Math.min(off, Math.max(0, (player.duration || off + 1) - 0.25)); player.play(); };\n    if (!player.src.endsWith(item.clip)) { player.src = item.clip; player.addEventListener('loadedmetadata', go, {once: true}); player.load(); }\n    else go();\n    now.textContent = label; bar.hidden = false;\n    document.querySelectorAll('[data-bout]').forEach(el => el.classList.toggle('on', isBout && +el.dataset.bout === item.i));\n    document.querySelectorAll('.band').forEach(el => el.classList.toggle('on', isBout && +el.dataset.i === item.i));\n  }\n  const playBout = (b, t) => play(b, t, `Snoring at ${fmt(t, true)} · bout of ${b.sounds} snores from ${fmt(b.startMs)}`, true);\n  if (area) {\n    area.addEventListener('mousemove', ev => {\n      const t = timeAt(ev), b = boutAt(t), m = Math.floor((t - D.start) / 60000);\n      cursor.style.left = pct(t); tip.style.left = pct(t); cursor.hidden = tip.hidden = false;\n      tip.textContent = b ? `${fmt(t)} · ${D.perMin[m] || 0} snores/min · click to listen`\n                          : (nearest(t) ? `${fmt(t)} · click for the nearest snoring` : `${fmt(t)} · no snoring nearby`);\n    });\n    area.addEventListener('mouseleave', () => { cursor.hidden = tip.hidden = true; });\n    area.addEventListener('click', ev => {\n      const t = timeAt(ev), b = boutAt(t);\n      if (b) playBout(b, Math.min(Math.max(t, b.startMs), b.endMs));\n      else { const n = nearest(t); if (n) playBout(n, n.peakMs); }\n    });\n  }\n  document.querySelectorAll('[data-bout]').forEach(el => el.addEventListener('click', () => {\n    const b = D.bouts[+el.dataset.bout]; playBout(b, b.peakMs); }));\n  document.querySelectorAll('[data-gasp]').forEach(el => el.addEventListener('click', ev => {\n    ev.stopPropagation(); const g = D.gasps[+el.dataset.gasp];\n    play(g, g.tMs, `Possible gasp at ${fmt(g.tMs, true)}`, false); }));\n  player.addEventListener('timeupdate', () => {\n    if (!current) return; head.style.left = pct(current.clipStartMs + player.currentTime * 1000); head.hidden = false; });\n  player.addEventListener('ended', () => { head.hidden = true; });\n})();\n"


# --------------------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("night", nargs="?", help="folder under <data>/nights, or a path")
    ap.add_argument("--data", type=Path, default=DATA)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--strict", action="store_true",
                    help="count with the phone app's detector (needs snores 12 dB above the room) instead of the AI-led rules")
    ap.add_argument("--keep-hum", action="store_true",
                    help="skip the 60 Hz hum filter (it is on by default)")
    ap.add_argument("--clean-levels", action="store_true",
                    help="measure loudness on hiss-removed audio (for a noisy mic)")
    ap.add_argument("--param", action="append", default=[], metavar="KEY=VALUE",
                    help="override a detector parameter, e.g. GATE_CLAMP_LO=-70")
    a = ap.parse_args()

    nights = a.data / "nights"
    if a.night and Path(a.night).is_dir():
        night_dir = Path(a.night)
    elif a.night:
        night_dir = nights / a.night
    else:
        dirs = sorted(d for d in nights.glob("*") if d.is_dir() and any(d.glob("*.wav")))
        if not dirs:
            raise SystemExit(f"no nights in {nights}; run pi/pull.sh first")
        night_dir = dirs[-1]
    if not night_dir.is_dir():
        raise SystemExit(f"{night_dir} does not exist")

    print(f"Analyzing {night_dir} …")
    overrides = {k: float(v) for k, v in (kv.split("=", 1) for kv in a.param)}
    s = analyze(night_dir, a.data / "reports" / night_dir.name, a.clean_levels, overrides,
                "spec" if a.strict else "ai", not a.keep_hum)
    report = a.data / "reports" / night_dir.name / "report.html"
    print(f"  {hm(s['recordedMs'])} recorded, {s['frames']:,} frames in {s['analysisSeconds']} s")
    print(f"  snoring: {hm(s['snoreMs']) if s['snoreMs'] else 'none'} "
          f"({s['percentOfNight']}% of the night) in {len(s['episodes'])} "
          f"{'bout' if s['mode'] == 'ai' else 'episode'}(s)")
    print(f"  possible gasps: {len(s['gaspCandidates'])}")
    print(f"  report: {report}")
    if not a.no_open:
        subprocess.run(["open", str(report)], check=False)


if __name__ == "__main__":
    main()
