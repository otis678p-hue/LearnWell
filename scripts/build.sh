#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This app targets macOS 26+ on Apple Silicon.' >&2
  exit 1
fi
xcrun --find swiftc >/dev/null
exec bash "${ROOT}/app/tools/build_app.sh"
