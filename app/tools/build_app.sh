#!/bin/bash
# Builds LearnWell.app with Command Line Tools only (no Xcode).
# Bundle inputs are tracked in Config/ and Resources/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep source paths intact when the repository path contains spaces.
SWIFT_SOURCES=()
while IFS= read -r -d '' source; do
  SWIFT_SOURCES+=("${source}")
done < <(find "${ROOT}/Sources" -name '*.swift' -print0)

PRODUCT_NAME="${PRODUCT_NAME:-LearnWell}"
EXECUTABLE_NAME="INT4154PostureDetection"
BUILD="${ROOT}/build"
OUTPUT="${BUILD}/${PRODUCT_NAME}.app"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "${BUILD}"

echo "==> checking localisation coverage"
swiftc -O -parse-as-library -sdk "${SDK}" -o "${BUILD}/check_localization" \
  "${ROOT}/tools/check_localization.swift"
"${BUILD}/check_localization" "${ROOT}"

echo "==> compiling Swift sources"
SWIFT_FLAGS=(-O -parse-as-library)
if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
  # Keep local source paths out of distributed executables.
  SWIFT_FLAGS+=(-file-prefix-map "${ROOT}=/LearnWell/app")
  RELEASE_SOURCES=()
  for source in "${SWIFT_SOURCES[@]}"; do
    RELEASE_SOURCES+=("${source#${ROOT}/}")
  done
  SWIFT_SOURCES=("${RELEASE_SOURCES[@]}")
  cd "${ROOT}"
fi
swiftc "${SWIFT_FLAGS[@]}" -target arm64-apple-macos26.0 -sdk "${SDK}" \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework CoreML -framework CoreImage -framework Vision \
  -framework IOKit -framework ServiceManagement -framework Security \
  -framework UniformTypeIdentifiers -framework OSLog \
  -o "${BUILD}/${EXECUTABLE_NAME}" \
  "${SWIFT_SOURCES[@]}" 2>&1 | tee "${BUILD}/compile.log"

for table in "${ROOT}/Sources/en.lproj/Localizable.strings" "${ROOT}/Sources/zh-Hant.lproj/Localizable.strings"; do
  size=$(wc -c < "${table}" | tr -d ' ')
  if [ "${size}" -gt 300000 ]; then
    echo "strings table too large (${size} bytes): ${table}" >&2
    exit 1
  fi
done

echo "==> assembling bundle"
rm -rf "${OUTPUT}"
mkdir -p "${OUTPUT}/Contents/Resources"
cp "${ROOT}/Config/BundleInfo.plist" "${OUTPUT}/Contents/Info.plist"
cp "${ROOT}/Resources/AppIcon.icns" "${OUTPUT}/Contents/Resources/AppIcon.icns"
cp "${ROOT}/../licenses/APACHE-2.0.txt" "${OUTPUT}/Contents/Resources/LICENSE.txt"
printf '%s' 'APPL????' > "${OUTPUT}/Contents/PkgInfo"
mkdir -p "${OUTPUT}/Contents/MacOS"
cp "${BUILD}/${EXECUTABLE_NAME}" "${OUTPUT}/Contents/MacOS/${EXECUTABLE_NAME}"

RESOURCES="${OUTPUT}/Contents/Resources"
mkdir -p "${RESOURCES}"

# Pose inference runs in a persistent local Python worker. The prepared Python
# environment remains external to this development bundle (see README).
mkdir -p "${RESOURCES}/Pose"
cp "${ROOT}/Bridge/mediapipe_pose.py" "${RESOURCES}/Pose/mediapipe_pose.py"

# Classroom worker and starting weights.
mkdir -p "${RESOURCES}/Classroom"
cp "${ROOT}/Bridge/yolo_classroom.py" "${RESOURCES}/Classroom/yolo_classroom.py"
cp "${ROOT}/../models/sitting_posture_yolo26n.pt" "${RESOURCES}/Classroom/sitting_posture_yolo26n.pt"

rm -rf "${RESOURCES}/PostureYOLO.mlmodelc"
cp -R "${ROOT}/Sources/PostureYOLO.mlmodelc" "${RESOURCES}/PostureYOLO.mlmodelc"
cp "${ROOT}/Sources/ThirdParty/PostureModel/LICENSE.txt" \
   "${RESOURCES}/PostureModel-LICENSE.txt"
cp "${ROOT}/Sources/ThirdParty/DorsoPostureResponse/LICENSE.txt" \
   "${RESOURCES}/DorsoPostureResponse-LICENSE.txt"

for lproj in zh-Hant en; do
  rm -rf "${RESOURCES}/${lproj}.lproj"
  cp -R "${ROOT}/Sources/${lproj}.lproj" "${RESOURCES}/${lproj}.lproj"
  # Translated macOS permission prompts; a missing file silently falls back to one language.
  plutil -lint "${RESOURCES}/${lproj}.lproj/InfoPlist.strings" >/dev/null
done

echo "==> checking bundled localisation"
bash "${ROOT}/tools/run_localization_bundle_check.sh" "${OUTPUT}"

echo "==> merging Info.plist"
python3 - "${OUTPUT}/Contents/Info.plist" "${ROOT}/Config/AppInfo.plist" "${PRODUCT_NAME}" "${EXECUTABLE_NAME}" <<PY
import plistlib, sys

target_path, overlay_path, product_name, executable = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(target_path, "rb") as handle:
    target = plistlib.load(handle)
with open(overlay_path, "rb") as handle:
    overlay = plistlib.load(handle)
for key, value in overlay.items():
    if key == "NSAppTransportSecurity":
        target.setdefault(key, {}).setdefault("NSExceptionDomains", {}).update(
            value.get("NSExceptionDomains", {})
        )
    else:
        target[key] = value
target.pop("NSMotionUsageDescription", None)
target["CFBundleName"] = product_name
target["CFBundleDisplayName"] = product_name
target["CFBundleExecutable"] = executable
with open(target_path, "wb") as handle:
    plistlib.dump(target, handle)
PY

SIGNING_IDENTITY="${NOTCH_SIGNING_IDENTITY:-Notch Triage Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_IDENTITY}"; then
  echo "==> signing with \"${SIGNING_IDENTITY}\""
  codesign --force --deep --sign "${SIGNING_IDENTITY}" "${OUTPUT}" >/dev/null
else
  echo "==> signing (ad-hoc)"
  codesign --force --deep --sign - "${OUTPUT}" >/dev/null
fi
codesign --verify --deep --strict "${OUTPUT}"

echo "==> bundled model: $(du -sh "${RESOURCES}/PostureYOLO.mlmodelc" | cut -f1) \
sha256 $(shasum -a 256 "${RESOURCES}/PostureYOLO.mlmodelc/weights/weight.bin" | cut -c1-12)"

if [[ "${INSTALL:-0}" == "1" ]]; then
  DEST="/Applications/${PRODUCT_NAME}.app"
  echo "==> installing to ${DEST}"
  osascript -e 'tell application id "com.hyacinth.notchtriage" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x "${EXECUTABLE_NAME}" 2>/dev/null || true
  rm -rf "${DEST}"
  cp -R "${OUTPUT}" "${DEST}"
  codesign --verify --deep --strict "${DEST}"
  echo "==> installed: ${DEST}"
  echo "    the camera grant survives because the signing identity is unchanged"
fi

echo "==> done: ${OUTPUT}"
