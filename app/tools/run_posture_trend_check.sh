#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
for source in PostureTrend PostureSession PostureHistoryFile PostureSnapshot PostureClassifier; do
  cp "${ROOT}/Sources/${source}.swift" "${WORK}/"
done
cp "${ROOT}/tools/posture_trend_check.swift" "${WORK}/"
swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "${WORK}/cache" -o "${WORK}/trend-check" "${WORK}/"*.swift
"${WORK}/trend-check"
