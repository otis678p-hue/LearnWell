#!/bin/bash
# Runs the exported CoreML posture model over sample images and reports what the
# app would show, without a camera, a test bundle or a full Xcode install.
#   bash tools/run_posture_model_check.sh                       # generated blank frame
#   bash tools/run_posture_model_check.sh path/to/photo.jpg ...  # your own photos
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MODEL="${ROOT}/Sources/PostureYOLO.mlmodelc"

cp "${ROOT}/tools/posture_model_check.swift" "${WORK}/main.swift"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos26.0 \
  -framework AppKit -framework CoreML -framework CoreVideo -framework CoreImage -framework IOKit \
  -o "${WORK}/posture-model-check" \
  "${WORK}/main.swift" \
  "${ROOT}/Sources/BackgroundDetectionPolicy.swift" \
  "${ROOT}/Sources/PostureClassifier.swift" \
  "${ROOT}/Sources/PosturePreviewOverlay.swift" \
  "${ROOT}/Sources/Localization.swift" \
  "${ROOT}/Sources/PosturePoseFallback.swift" \
  "${ROOT}/Sources/PostureHistoryFile.swift" \
  "${ROOT}/Sources/PostureResponse.swift" \
  "${ROOT}/Sources/PostureSerialLink.swift" \
  "${ROOT}/Sources/PostureSession.swift" \
  "${ROOT}/Sources/PostureSnapshot.swift" \
  "${ROOT}/Sources/PostureTrend.swift"
"${WORK}/posture-model-check" "${MODEL}" "$@"
