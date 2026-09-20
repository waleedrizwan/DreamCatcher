"""Usage: python level_experiment.py [clip-root]

Does input level change YAMNet's snoring score? Score each clip at its native
level and after peak-normalizing to 0.5 (gain capped at +30 dB)."""
import sys, os, glob, csv
sys.path.insert(0, 'src')
import numpy as np, soundfile as sf
import coremltools as ct
W = 15600
ml = ct.models.MLModel('YAMNet.mlpackage', compute_units=ct.ComputeUnit.CPU_ONLY)
root = sys.argv[1] if len(sys.argv) > 1 else 'data/Snoring_Dataset_@16000'  # see README: clip set
def load(p):
    x, sr = sf.read(p, dtype='float32')
    if x.ndim > 1: x = x.mean(1)
    x = x[:W]; return np.pad(x, (0, W - len(x)))
def score(x): return float(ml.predict({'waveform': x.astype(np.float32)})['scores'][0][38])
def normalize(x, target=0.5, max_gain_db=30.0):
    peak = float(np.max(np.abs(x))) + 1e-9
    g = min(target / peak, 10 ** (max_gain_db / 20))
    return np.clip(x * g, -1, 1)
def dbfs(x): return 20*np.log10(np.sqrt(np.mean(x**2)) + 1e-9)
res = {}
for sub in ['snoring', 'no_snoring']:
    rows = []
    for p in sorted(glob.glob(f'{root}/{sub}/*.wav')):
        x = load(p); rows.append((os.path.basename(p), dbfs(x), score(x), score(normalize(x))))
    res[sub] = rows
snore = res['snoring']; non = res['no_snoring']
lvl = np.array([r[1] for r in snore]); nat = np.array([r[2] for r in snore]); nrm = np.array([r[3] for r in snore])
print(f"snoring clips: rms dBFS median {np.median(lvl):.1f}, p10 {np.percentile(lvl,10):.1f}, p90 {np.percentile(lvl,90):.1f}")
print(f"  native:     {100*(nat>=0.35).mean():.0f}% >= 0.35   median score {np.median(nat):.2f}")
print(f"  normalized: {100*(nrm>=0.35).mean():.0f}% >= 0.35   median score {np.median(nrm):.2f}")
quiet = lvl < np.percentile(lvl, 25)
print(f"  quietest quarter (rms < {np.percentile(lvl,25):.1f} dBFS): native {100*(nat[quiet]>=0.35).mean():.0f}% -> normalized {100*(nrm[quiet]>=0.35).mean():.0f}%")
loud = lvl >= np.percentile(lvl, 75)
print(f"  loudest quarter: native {100*(nat[loud]>=0.35).mean():.0f}% -> normalized {100*(nrm[loud]>=0.35).mean():.0f}%")
# What happens to a good snore when attenuated as if the phone were far away?
good = [r for r in snore if r[2] >= 0.8][:40]
for att in [0, 12, 24, 36]:
    sc = [score(load(f'{root}/snoring/{r[0]}') * 10**(-att/20)) for r in good]
    scn = [score(normalize(load(f'{root}/snoring/{r[0]}') * 10**(-att/20))) for r in good]
    print(f"  40 strong snores attenuated {att:2d} dB: native {100*np.mean(np.array(sc)>=0.35):.0f}% >= 0.35, normalized {100*np.mean(np.array(scn)>=0.35):.0f}%")
nn = np.array([r[2] for r in non]); nnn = np.array([r[3] for r in non])
print(f"non-snoring: native {100*(nn>=0.35).mean():.1f}% false, normalized {100*(nnn>=0.35).mean():.1f}% false (max normalized score {nnn.max():.2f})")
top = sorted(snore, key=lambda r: -r[2])[:2]; mid = sorted(snore, key=lambda r: abs(r[2]-0.5))[:1]; neg = sorted(non, key=lambda r: -r[2])[:1]
print("CHECKFILES", ' '.join(f"{root}/snoring/{r[0]}" for r in top+mid), f"{root}/no_snoring/{neg[0][0]}")
print("CHECKSCORES", [(r[0], round(r[2],4)) for r in top+mid+neg])
