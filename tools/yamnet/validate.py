"""Usage: python validate.py [clip-root]

Score the 1,000-clip snoring/non-snoring set with the TF reference and the
Core ML model; report agreement, separation at the spec thresholds, and CPU latency."""
import sys, os, glob, time, csv
sys.path.insert(0, 'src')
import numpy as np, soundfile as sf, tensorflow as tf
import coremltools as ct
import params as yp, yamnet as ym
W = 15600
ref = ym.yamnet_frames_model(yp.Params()); ref.load_weights('yamnet.h5')
ml = ct.models.MLModel('YAMNet.mlpackage', compute_units=ct.ComputeUnit.CPU_ONLY)
names = [r[2] for r in list(csv.reader(open('src/yamnet_class_map.csv')))[1:]]
SNORE, SPEECH = names.index('Snoring'), names.index('Speech')
root = sys.argv[1] if len(sys.argv) > 1 else 'data/Snoring_Dataset_@16000'  # see README: clip set
def load(p):
    x, sr = sf.read(p, dtype='float32'); assert sr == 16000
    if x.ndim > 1: x = x.mean(1)
    x = x[:W]
    return np.pad(x, (0, W - len(x)))
rows = []
lat = []
for label, sub in [(1, 'snoring'), (0, 'no_snoring')]:
    for p in sorted(glob.glob(f'{root}/{sub}/*.wav')):
        x = load(p)
        t = ref(x)[0].numpy()[0]
        t0 = time.perf_counter(); c = ml.predict({'waveform': x})['scores'][0]; lat.append(time.perf_counter() - t0)
        rows.append((label, t[SNORE], c[SNORE], c[SPEECH], float(np.max(np.abs(t - c))), os.path.basename(p)))
lab = np.array([r[0] for r in rows]); tfs = np.array([r[1] for r in rows]); cms = np.array([r[2] for r in rows]); sp = np.array([r[3] for r in rows])
print(f'clips: {len(rows)}  max|tf-coreml| over all classes: {max(r[4] for r in rows):.2e}')
print(f'coreml latency (Mac CPU): median {np.median(lat)*1000:.1f} ms, p95 {np.percentile(lat,95)*1000:.1f} ms')
# AUC via rank statistic
pos, neg = cms[lab==1], cms[lab==0]
auc = (pos[:,None] > neg[None,:]).mean() + 0.5*(pos[:,None] == neg[None,:]).mean()
print(f'snoring-score AUC: {auc:.3f}')
for q in [10,25,50,75,90]: print(f'  snoring clips p{q}: {np.percentile(pos,q):.2f}   non-snoring p{q}: {np.percentile(neg,q):.2f}')
for thr in [0.22, 0.35, 0.50, 0.60]:
    print(f'  thr {thr:.2f}: detects {100*(pos>=thr).mean():.0f}% of snoring clips, flags {100*(neg>=thr).mean():.1f}% of non-snoring clips')
print(f'speech score >= 0.5 on snoring clips: {100*(sp[lab==1]>=0.5).mean():.1f}%')
# Top-scoring non-snoring clips and lowest-scoring snoring clips
worst_fp = sorted([r for r in rows if r[0]==0], key=lambda r: -r[2])[:5]
worst_fn = sorted([r for r in rows if r[0]==1], key=lambda r: r[2])[:5]
print('highest non-snoring:', [(r[5], round(float(r[2]),2)) for r in worst_fp])
print('lowest snoring:', [(r[5], round(float(r[2]),2)) for r in worst_fn])
