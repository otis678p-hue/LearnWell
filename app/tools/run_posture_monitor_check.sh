#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep source paths intact when the repository path contains spaces.
SWIFT_SOURCES=()
while IFS= read -r -d '' source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources" -name '*.swift' ! -name 'PostureApp.swift' -print0)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
swiftc -Onone -g -parse-as-library -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreML -framework CoreImage -framework Vision \
  -framework IOKit -framework ServiceManagement -framework Security \
  -framework UniformTypeIdentifiers -framework OSLog \
  -o "${WORK}/check" "${ROOT}/tools/posture_monitor_check.swift" \
  "${SWIFT_SOURCES[@]}"
APP="${WORK}/Monitor Check.app"
mkdir -p "${APP}/Contents/MacOS"
cp "${WORK}/check" "${APP}/Contents/MacOS/check"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.posture.monitor-check.$RANDOM</string><key>CFBundleExecutable</key><string>check</string></dict></plist>
PLIST
POSTURE_HISTORY_PATH="${WORK}/history.json" "${APP}/Contents/MacOS/check"
