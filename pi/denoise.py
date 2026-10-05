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


# --- mains hum ---------------------------------------------------------------
# The bedside USB mic picks up 60 Hz electrical hum and its harmonics (60, 180,
# 300, 540 Hz… measured 2026-10-05; it is not the air purifier), plus slow
# sub-20 Hz level jumps every ~2 s. Hum is a set of exact, stable tones, so
# narrow notches remove it while costing snoring almost nothing: Gaussian
# notches ~2.5 Hz wide up to 1.5 kHz take out ~1.6% of that band.
#
# Done in the frequency domain over the whole buffer (one FFT per 10-minute
# file, ~1 s) rather than with IIR filters (~20 s per file at this length).
HUM_BASE_HZ = 60.0
HUM_MAX_HZ = 1500.0
HUM_NOTCH_SIGMA_HZ = 0.75      # Gaussian notch; -6 dB width ≈ 2.5 Hz
HIGHPASS_LO_HZ, HIGHPASS_HI_HZ = 25.0, 45.0   # raised-cosine ramp: 0 below 25 Hz, 1 above 45 Hz
_PAD_S = 1.0


def remove_hum(x: np.ndarray, sr: int = 16000) -> np.ndarray:
    """High-pass + mains-harmonic notches, zero phase. Same length as x."""
    x = np.asarray(x, dtype=np.float64)
    pad = min(int(_PAD_S * sr), len(x) - 1)
    xp = np.pad(x, (pad, pad), mode="reflect") if pad > 0 else x
    n = len(xp)
    X = np.fft.rfft(xp)
    f = np.fft.rfftfreq(n, 1 / sr)
    gain = np.clip((f - HIGHPASS_LO_HZ) / (HIGHPASS_HI_HZ - HIGHPASS_LO_HZ), 0, 1)
    gain = 0.5 - 0.5 * np.cos(np.pi * gain)
    k = HUM_BASE_HZ
    while k <= HUM_MAX_HZ:
        lo, hi = np.searchsorted(f, [k - 6 * HUM_NOTCH_SIGMA_HZ, k + 6 * HUM_NOTCH_SIGMA_HZ])
        gain[lo:hi] *= 1 - np.exp(-0.5 * ((f[lo:hi] - k) / HUM_NOTCH_SIGMA_HZ) ** 2)
        k += HUM_BASE_HZ
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
