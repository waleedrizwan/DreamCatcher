#!/usr/bin/env python3
"""Remove the USB mic's steady hiss so breathing and snoring are easy to hear.

Spectral gating, numpy only. The hiss is the mic's own electronic noise: it is
stationary (the same spectrum all night), so its profile can be measured from
the quietest moments and subtracted everywhere. Per frequency bin:

    noise[f]   = a low percentile of |STFT| over time (breaths are brief; hiss is always there)
    mask[t, f] = soft step from 0 to 1 as |STFT| rises from 1.5x to 3x noise[f]

The mask is smoothed across neighbouring frames and bins to avoid "musical
noise" chirps, and floored at -24 dB so the room keeps a natural trace of
sound instead of dropping to digital silence.

This is for LISTENING (clips in the report). Detection still runs on the raw
audio so its numbers stay comparable with the iPhone app.

Usage: denoise.py IN.wav OUT.wav [--boost]
"""
from __future__ import annotations

import argparse
import wave

import numpy as np

N_FFT, HOP = 1024, 256          # 64 ms frames, 16 ms hop at 16 kHz
NOISE_PERCENTILE = 20
GATE_LO, GATE_HI = 1.5, 3.0     # x noise: below LO fully suppressed, above HI fully kept
FLOOR_DB = -24.0


def _stft(x: np.ndarray) -> np.ndarray:
    win = np.hanning(N_FFT + 1)[:-1]
    pad = np.pad(x, (N_FFT // 2, N_FFT // 2 + HOP), mode="reflect")
    n = 1 + (len(pad) - N_FFT) // HOP
    frames = np.lib.stride_tricks.sliding_window_view(pad, N_FFT)[::HOP][:n]
    return np.fft.rfft(frames * win, axis=1)


def _istft(X: np.ndarray, length: int) -> np.ndarray:
    win = np.hanning(N_FFT + 1)[:-1]
    frames = np.fft.irfft(X, n=N_FFT, axis=1) * win
    out = np.zeros(HOP * (len(frames) - 1) + N_FFT)
    norm = np.zeros_like(out)
    for i, f in enumerate(frames):
        out[i * HOP:i * HOP + N_FFT] += f
        norm[i * HOP:i * HOP + N_FFT] += win ** 2
    out /= np.maximum(norm, 1e-8)
    return out[N_FFT // 2:N_FFT // 2 + length]


def _smooth(m: np.ndarray, t: int = 3, f: int = 5) -> np.ndarray:
    """Moving average over time then frequency (edges padded by repetition)."""
    for axis, k in ((0, t), (1, f)):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (k // 2, k // 2)
        mp = np.pad(m, pad, mode="edge")
        c = np.cumsum(mp, axis=axis)
        c = np.insert(c, 0, 0, axis=axis)
        m = (np.take(c, range(k, c.shape[axis]), axis=axis)
             - np.take(c, range(0, c.shape[axis] - k), axis=axis)) / k
    return m


def denoise(x: np.ndarray, noise_profile: np.ndarray | None = None) -> np.ndarray:
    """x: float audio at 16 kHz. Returns the cleaned signal, same length.
    Pass noise_profile (from noise_profile()) to reuse one measured elsewhere."""
    x = x - np.mean(x)                         # this mic has a small DC offset
    X = _stft(x)
    mag = np.abs(X)
    noise = noise_profile if noise_profile is not None else np.percentile(mag, NOISE_PERCENTILE, axis=0)
    ratio = mag / np.maximum(noise, 1e-12)
    mask = np.clip((ratio - GATE_LO) / (GATE_HI - GATE_LO), 0.0, 1.0)
    mask = np.maximum(_smooth(mask), 10 ** (FLOOR_DB / 20))
    return _istft(X * mask, len(x))


# --- steady tones (hum) -------------------------------------------------------
# A bedroom recording carries several hums at once: 60 Hz mains pickup and its
# harmonics, plus whatever motors are running (night 2026-10-05: a fan or
# motor at a rock-steady 55.6 Hz with harmonics, and smaller lines at 39, 62.5,
# 1000 and 4000 Hz). Anything that holds the exact same pitch for 10 minutes
# is a machine; snoring and breathing never do. So find_tones() measures the
# long-term spectrum of a buffer and returns every narrow peak standing well
# above its surroundings, and remove_hum() notches those plus the 60 Hz
# family, and drops the sub-25 Hz level jumps this USB mic makes.
#
# Done in the frequency domain over the whole buffer (one FFT per 10-minute
# file) rather than with IIR filters (~20 s per file at this length).
HUM_BASE_HZ = 60.0
HUM_MAX_HZ = 1500.0
HUM_NOTCH_SIGMA_HZ = 0.75      # Gaussian notch; -6 dB width ≈ 2.5 Hz
HIGHPASS_LO_HZ, HIGHPASS_HI_HZ = 25.0, 45.0   # raised-cosine ramp: 0 below 25 Hz, 1 above 45 Hz
# The capture chain also adds lines at exact multiples of sample_rate/256
# (62.5 Hz at 16 kHz: 125, 250, 500 Hz…), intermittent so find_tones misses
# them, strongest at 250 Hz (~15-20 dB above the room at night).
DIGITAL_DIVISOR = 256
DIGITAL_MAX_HZ = 1000.0
DIGITAL_SIGMA_HZ = 0.4
TONE_PROMINENCE_DB = 7.0       # how far a line must stand above the spectrum ±10 Hz around it
TONE_MIN_HZ, TONE_MAX_HZ = 25.0, 7800.0
TONE_SIGMA_HZ = 0.6
TONE_MAX_COUNT = 60            # safety cap: never carve more than this many notches
_WELCH_N = 262144              # 16.4 s segments: 0.06 Hz resolution (machine hums are that steady)
_PAD_S = 1.0


def find_tones(x: np.ndarray, sr: int = 16000) -> list[float]:
    """Frequencies (Hz) of steady narrowband lines in x, strongest first."""
    x = np.asarray(x, dtype=np.float64)
    x = x - x.mean()
    n = _WELCH_N
    while n > 4096 and len(x) < 4 * n:
        n //= 2
    if len(x) < n:
        return []
    segs = np.lib.stride_tricks.sliding_window_view(x, n)[::n // 2]
    P = np.mean(np.abs(np.fft.rfft(segs * np.hanning(n), axis=1)) ** 2, axis=0)
    f = np.fft.rfftfreq(n, 1 / sr)
    L = 10 * np.log10(P + 1e-30)
    half = max(2, int(round(10.0 / (f[1] - f[0]))))
    med = np.median(np.lib.stride_tricks.sliding_window_view(np.pad(L, half, mode="edge"), 2 * half + 1), axis=1)
    prom = L - med
    is_peak = np.zeros_like(L, dtype=bool)
    is_peak[2:-2] = ((L[2:-2] >= L[1:-3]) & (L[2:-2] >= L[3:-1]) & (L[2:-2] >= L[:-4]) & (L[2:-2] >= L[4:]))
    idx = np.where(is_peak & (prom >= TONE_PROMINENCE_DB) & (f >= TONE_MIN_HZ) & (f <= TONE_MAX_HZ))[0]
    idx = idx[np.argsort(-prom[idx])][:TONE_MAX_COUNT]
    tones = []
    for i in idx:   # parabolic interpolation for a sub-bin frequency
        a, b, c = L[i - 1], L[i], L[i + 1]
        d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
        tones.append(float(f[i] + d * (f[1] - f[0])))
    return tones


def night_tones(per_file: list[list[float]], min_share: float = 0.1, tol_hz: float = 0.25) -> list[float]:
    """Tones found in at least min_share of the night's files (and at least two).
    A machine that hums all night can dip under the detection threshold in a
    file full of snoring; pooling the night catches it there too."""
    found = sorted((t, i) for i, ts in enumerate(per_file) for t in ts)
    need = max(2, int(np.ceil(min_share * len(per_file))))
    out, group = [], []
    for t, i in found + [(float("inf"), -1)]:
        if group and t - group[-1][0] > tol_hz:
            if len({j for _, j in group}) >= need:
                out.append(float(np.median([g for g, _ in group])))
            group = []
        group.append((t, i))
    return out


def merge_tones(*lists: list[float], tol_hz: float = 0.2) -> list[float]:
    out: list[float] = []
    for t in sorted(t for ts in lists for t in ts):
        if not out or t - out[-1] > tol_hz:
            out.append(t)
    return out


def remove_hum(x: np.ndarray, sr: int = 16000, tones: list[float] | None = None) -> np.ndarray:
    """High-pass + 60 Hz family + every steady tone, zero phase. Same length as x.
    tones: from find_tones(); measured on x itself when omitted."""
    x = np.asarray(x, dtype=np.float64)
    if tones is None:
        tones = find_tones(x, sr)
    pad = min(int(_PAD_S * sr), len(x) - 1)
    xp = np.pad(x, (pad, pad), mode="reflect") if pad > 0 else x
    n = len(xp)
    X = np.fft.rfft(xp)
    f = np.fft.rfftfreq(n, 1 / sr)
    gain = np.clip((f - HIGHPASS_LO_HZ) / (HIGHPASS_HI_HZ - HIGHPASS_LO_HZ), 0, 1)
    gain = 0.5 - 0.5 * np.cos(np.pi * gain)
    notches = [(k * HUM_BASE_HZ, HUM_NOTCH_SIGMA_HZ) for k in range(1, int(HUM_MAX_HZ // HUM_BASE_HZ) + 1)]
    base = sr / DIGITAL_DIVISOR
    notches += [(k * base, DIGITAL_SIGMA_HZ) for k in range(1, int(DIGITAL_MAX_HZ // base) + 1)]
    notches += [(t, TONE_SIGMA_HZ) for t in tones]
    for centre, sigma in notches:
        lo, hi = np.searchsorted(f, [centre - 6 * sigma, centre + 6 * sigma])
        gain[lo:hi] *= 1 - np.exp(-0.5 * ((f[lo:hi] - centre) / sigma) ** 2)
    y = np.fft.irfft(X * gain, n=n)
    return y[pad:pad + len(x)] if pad > 0 else y


def noise_profile(x: np.ndarray) -> np.ndarray:
    return np.percentile(np.abs(_stft(x - np.mean(x))), NOISE_PERCENTILE, axis=0)


def boost(x: np.ndarray, target_peak: float = 0.5) -> np.ndarray:
    """Turn up for listening: 99.9th-percentile sample to target_peak."""
    ref = np.percentile(np.abs(x), 99.9)
    return x * (target_peak / ref) if ref > 0 else x


def read_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path) as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1, "16-bit mono only"
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768, w.getframerate()


def write_wav(path: str, x: np.ndarray, sr: int = 16000) -> None:
    y = np.clip(np.round(x * 32768), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(y.tobytes())


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Remove steady mic hiss from a 16 kHz mono WAV.")
    ap.add_argument("inp"); ap.add_argument("out")
    ap.add_argument("--boost", action="store_true", help="also turn it up for listening")
    a = ap.parse_args()
    x, sr = read_wav(a.inp)
    y = denoise(x)
    write_wav(a.out, boost(y) if a.boost else y, sr)
