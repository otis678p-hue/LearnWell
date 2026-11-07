#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "${WORK}/cache" -o "${WORK}/heatmap-check" \
  "${ROOT}/tools/posture_heatmap_check.swift" \
  "${ROOT}/Sources/PostureHeatmap.swift" \
  "${ROOT}/Sources/PostureSession.swift" \
  "${ROOT}/Sources/PostureHistoryFile.swift" \
  "${ROOT}/Sources/PostureSnapshot.swift" \
  "${ROOT}/Sources/PostureClassifier.swift"
"${WORK}/heatmap-check"
