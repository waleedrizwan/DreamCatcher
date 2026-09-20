# tools/yamnet — the bundled classifier, reproducibly

The app ships `ios/Packages/SnoreAudio/Sources/SnoreAudio/Resources/YAMNet.mlmodelc`
(+ `yamnet_class_map.csv`). This directory rebuilds it from Google's released
YAMNet so nobody has to trust a binary blob.

Why YAMNet, CPU-only: Spike 0 on a physical iPhone 17 / iOS 26.6 (2026-09-19)
showed Apple's built-in SoundAnalysis classifier dies with `SNError` code 2 the
moment the screen locks (iOS forbids background GPU work). A Core ML program
run with `computeUnits = .cpuOnly` is the path iOS allows all night.

## Rebuild

```sh
cd tools/yamnet
uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python -r requirements.txt
./fetch.sh                       # model definition + weights (sha256-checked)
.venv/bin/python convert.py      # → YAMNet.mlpackage (checks TF vs Core ML ≤ 1e-5)
xcrun coremlcompiler compile YAMNet.mlpackage compiled
rm -rf ../../ios/Packages/SnoreAudio/Sources/SnoreAudio/Resources/YAMNet.mlmodelc
cp -R compiled/YAMNet.mlmodelc src/yamnet_class_map.csv ../../ios/Packages/SnoreAudio/Sources/SnoreAudio/Resources/
```

Model contract (what `YAMNetClassifier.swift` relies on):

| | |
|---|---|
| input `waveform` | Float32 `[15600]` — 0.975 s of 16 kHz mono PCM in [-1, 1] (one YAMNet patch: 96 STFT frames of 25 ms / 10 ms hop, so no padding logic) |
| output `scores` | Float32 `[1, 521]` sigmoid per AudioSet class; `Snoring` = 38, `Speech` = 0 (from the class map, asserted at startup) |
| output `embeddings` | Float32 `[1, 1024]` (unused today; the hook for choking / teeth-grinding heads) |
| precision | Float32 weights and compute (15 MB); iOS 17 mlprogram |

The TFLite-compatible STFT (DFT as matmul) is used so the graph has no RFFT
op, which coremltools cannot convert (apple/coremltools#1529).

## Validate

The clip set used for the numbers below is the 1,000-clip snoring / non-snoring
set from github.com/adrianagaler/Snoring-Detection (`Snoring_Dataset_@16000`,
1 s clips, 16 kHz; sourced from online recordings — local evaluation only, not
redistributed here). Clone it to `data/` or pass its path.

```sh
.venv/bin/python validate.py data/Snoring_Dataset_@16000
.venv/bin/python level_experiment.py data/Snoring_Dataset_@16000
```

Results, 2026-09-19 (Mac, Core ML CPU-only):

- TF vs Core ML: max |Δ| 1.1e-5 over all 521 classes × 1,000 clips; 1.1 ms per window.
- Snoring-score AUC 0.986. At the spec's Medium threshold 0.35: 61 % of the
  1 s snoring clips score positive (many of the rest are partial breath
  cycles), **0.0 %** of the 500 non-snoring clips (baby crying, TV, talking,
  sirens, rain, clock, door, toilet, streetcar, silence).
- Level: 40 strong snores attenuated 36 dB (a phone across the room) fall to
  35 % detected at native level, 100 % after peak-normalizing each window to
  0.5 (gain ≤ +30 dB); normalization raises the non-snoring false-positive rate
  from 0.0 % to 0.0 % (max score 0.02). That is why the Swift classifier
  normalizes.

## Provenance

- Model definition: tensorflow/models `research/audioset/yamnet` (Apache 2.0).
- Weights: `https://storage.googleapis.com/audioset/yamnet.h5`,
  sha256 `13c3308955bbfaef262f175ac9c40e47b134573a93984f009220dd7cc12a1744`.
- Class map: `yamnet_class_map.csv` from the same directory (521 AudioSet classes).
