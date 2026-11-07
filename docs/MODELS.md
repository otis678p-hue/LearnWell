# Posture models

LearnWell includes a YOLO26n sitting-posture detector as a PyTorch checkpoint
and a compiled CoreML model. Classes are **0 = Bad**, **1 = Good**. The model
uses a 640 × 640 input with letterbox padding.

The checkpoint contains the inference model, basic inference arguments, version,
license, and documentation URL. Machine paths, training logs, run metrics,
optimizer state, and source checkout metadata are excluded. Model parameter and
buffer tensors are preserved. No training photos are distributed.

The compiled CoreML model enables native detection without model conversion.
`environment/model-manifest.json` records checksums for all supplied model files.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `models/sitting_posture_yolo26n.pt` | 5,487,842 | `ebcddb75047340d2543b53a69eb9cece781984b9fe204596a90bd38167c7e1ec` |
| `app/Sources/PostureYOLO.mlmodelc/analytics/coremldata.bin` | 243 | `97bea71f910474a679f48426ab9f04306a066efb48d4df37f84c7c1c899514bc` |
| `app/Sources/PostureYOLO.mlmodelc/coremldata.bin` | 826 | `ad0b46158a98de525768fb885ae75c52e7951b5e6f54dcc6888e0c1097b03a93` |
| `app/Sources/PostureYOLO.mlmodelc/model.mil` | 217,621 | `0a374d95cec36e7b4972ac4b1797f8ccd6b26f42d293721ed4792f40715f371c` |
| `app/Sources/PostureYOLO.mlmodelc/weights/weight.bin` | 4,844,000 | `052c7def699b46196a0327d3c8f6995b4c90fc772f3f65ef505895f8fdd1d0bd` |

## Export a replacement model

With the training Python environment installed, run from the repository root:

```bash
.venv/bin/python app/tools/convert_posture_model.py \
  models/sitting_posture_yolo26n.pt \
  app/build/PostureYOLO.mlpackage
swift app/tools/compile_posture_model.swift \
  app/build/PostureYOLO.mlpackage \
  app/Sources/PostureYOLO.mlmodelc
bash scripts/build.sh
```

Update the model manifest when intentionally replacing model files. MediaPipe
pose and face assets are installed in the separate `.venv-pose` environment by
`scripts/setup_environment.sh`.
