"""Convert YAMNet (TensorFlow, Apache 2.0) to a fixed-window Core ML model.

Input:  waveform  Float32 [15600]  — 0.975 s of 16 kHz mono PCM in [-1, 1]
Output: scores    Float32 [1, 521] — per-class sigmoid scores (AudioSet)
        embeddings Float32 [1, 1024]

15600 samples is exactly one YAMNet patch (96 STFT frames of 25 ms / 10 ms
hop), so no padding logic is needed and the graph is fully static. The
TFLite-compatible STFT (DFT as matmul) is used so nothing depends on RFFT ops
that coremltools cannot convert.
"""
import sys, os, csv
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'src'))
import numpy as np
import tensorflow as tf
from tensorflow.keras import Model, layers
import coremltools as ct
import params as yamnet_params
import yamnet as yamnet_model
import features as features_lib

WINDOW = 15600

def build_fixed(params):
    waveform = layers.Input(batch_shape=(WINDOW,), dtype=tf.float32, name='waveform')
    _, feats = features_lib.waveform_to_log_mel_spectrogram_patches(waveform, params)
    preds, emb = yamnet_model.yamnet(feats, params)
    preds = layers.Activation('linear', name='scores')(preds)
    emb = layers.Activation('linear', name='embeddings')(emb)
    return Model(name='yamnet_fixed', inputs=waveform, outputs=[preds, emb])

# Reference model (stock graph, tf.signal.stft) for numerical checks.
ref_params = yamnet_params.Params()
ref = yamnet_model.yamnet_frames_model(ref_params)
ref.load_weights('yamnet.h5')

fixed_params = yamnet_params.Params(tflite_compatible=True)
fixed = build_fixed(fixed_params)
assert len(fixed.get_weights()) == len(ref.get_weights())
fixed.set_weights(ref.get_weights())

# Sanity: identical outputs on random audio.
rng = np.random.default_rng(0)
x = (rng.standard_normal(WINDOW) * 0.1).astype(np.float32)
p_ref, _, _ = ref(x)
p_fix, _ = fixed(x[None] if False else x)
print('max |ref - fixed| on noise:', float(np.max(np.abs(p_ref.numpy()[0] - p_fix.numpy()[0]))))

mlmodel = ct.convert(
    fixed,
    source='tensorflow',
    inputs=[ct.TensorType(name='waveform', shape=(WINDOW,), dtype=np.float32)],
    convert_to='mlprogram',
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT32,
    compute_units=ct.ComputeUnit.CPU_ONLY,
)
# Keras output ops are anonymous ("Identity", "Identity_1"): rename by shape.
spec = mlmodel.get_spec()
for o in spec.description.output:
    dims = list(o.type.multiArrayType.shape)
    new = 'scores' if 521 in dims else 'embeddings'
    print('output', o.name, dims, '->', new)
    ct.utils.rename_feature(spec, o.name, new)
mlmodel = ct.models.MLModel(spec, weights_dir=mlmodel.weights_dir,
                            compute_units=ct.ComputeUnit.CPU_ONLY)
names = [row[2] for row in list(csv.reader(open('src/yamnet_class_map.csv')))[1:]]
mlmodel.short_description = 'YAMNet (AudioSet, 521 classes). Input 0.975 s of 16 kHz mono PCM; sigmoid class scores.'
mlmodel.author = 'Google (TensorFlow Model Garden, Apache 2.0); converted for Dream Catcher'
mlmodel.license = 'Apache License 2.0'
mlmodel.version = '1'
mlmodel.user_defined_metadata['class_map'] = ','.join(names)
mlmodel.user_defined_metadata['snoring_index'] = str(names.index('Snoring'))
mlmodel.user_defined_metadata['speech_index'] = str(names.index('Speech'))
mlmodel.save('YAMNet.mlpackage')
print('saved; Snoring idx', names.index('Snoring'), 'Speech idx', names.index('Speech'))

# Core ML vs TF on the same random input.
out = mlmodel.predict({'waveform': x})
print('coreml scores shape', out['scores'].shape, 'max |tf - coreml|:', float(np.max(np.abs(out['scores'][0] - p_ref.numpy()[0]))))
