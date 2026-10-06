#!/bin/sh
# Fetch YAMNet's model definition (TensorFlow Model Garden, Apache 2.0) and
# the released weights into ./src so convert.py can rebuild the Core ML model.
set -eu
cd "$(dirname "$0")"
mkdir -p src
BASE=https://raw.githubusercontent.com/tensorflow/models/master/research/audioset/yamnet
for f in yamnet.py params.py features.py yamnet_class_map.csv; do
  curl -sSL -o "src/$f" "$BASE/$f"
done
# Upstream imports the standalone tf_keras package; coremltools needs the
# tf.keras objects that ship inside TensorFlow 2.15.
sed -i '' 's/^from tf_keras import Model, layers/from tensorflow.keras import Model, layers/' src/yamnet.py
curl -sSL -o yamnet.h5 https://storage.googleapis.com/audioset/yamnet.h5
echo "13c3308955bbfaef262f175ac9c40e47b134573a93984f009220dd7cc12a1744  yamnet.h5" | shasum -a 256 -c -
echo "fetched"
