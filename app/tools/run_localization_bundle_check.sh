#!/bin/bash
# Test the exact localization resources in a built or installed app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${ROOT}/build/LearnWell.app}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CHECK="${WORK}/Localization Check.app/Contents"
mkdir -p "${CHECK}/MacOS" "${CHECK}/Resources"
for language in en zh-Hant; do
  cp -R "${APP}/Contents/Resources/${language}.lproj" "${CHECK}/Resources/"
done
cat > "${CHECK}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.posture.localization-check</string>
<key>CFBundleExecutable</key><string>check</string>
</dict></plist>
PLIST
swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" \
  "${ROOT}/Sources/Localization.swift" "${ROOT}/tools/localization_bundle_check.swift" \
  -o "${CHECK}/MacOS/check"
"${CHECK}/MacOS/check"
