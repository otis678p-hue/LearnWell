#!/bin/bash
set -euo pipefail
# Verifies posture decoding, NMS, letterbox mapping, serial parsing and ring rules
# without a camera, a test bundle or a full Xcode install.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos26.0"
SOURCES=(
  BackgroundDetectionPolicy.swift
  PostureHistoryFile.swift
  PostureSession.swift
  PostureTrend.swift
  PostureClassifier.swift
  PostureSnapshot.swift
  PostureSerialLink.swift
  PostureBlurSettings.swift
  PostureResponse.swift
  PosturePoseFallback.swift
)

# --- logic check (needs CoreML/CoreVideo/CoreImage/IOKit) ---
WORK1="$(mktemp -d)"
trap 'rm -rf "${WORK1}"' EXIT

for s in "${SOURCES[@]}"; do cp "${ROOT}/Sources/${s}" "${WORK1}/"; done
cp "${ROOT}/tools/posture_logic_check.swift" "${WORK1}/main.swift"
# Swift treats the file named main.swift as the executable entry point, and only
# there.
swiftc -O -sdk "${SDK}" -target "${TARGET}" \
  -framework CoreML -framework CoreVideo -framework CoreImage -framework IOKit \
  -framework Vision -framework AppKit \
  -o "${WORK1}/posture-logic-check" "${WORK1}/"*.swift
"${WORK1}/posture-logic-check"
