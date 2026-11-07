#!/bin/bash
# Shared entry point for Finder's double-click installers. Keep results visible.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || exit 1
# Finder launches may omit package-manager tools from PATH.
export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/opt/homebrew/bin:/usr/local/bin"

case "${1:-}" in
  app)
    echo 'Installing LearnWell into Applications...'
    echo 'Requires Apple Silicon, macOS 26+, and Apple Command Line Tools.'
    echo 'An existing LearnWell installation will be replaced.'
    echo
    INSTALL=1 /bin/bash "${ROOT}/scripts/build.sh"
    STATUS=$?
    if [[ ${STATUS} -eq 0 ]]; then
      echo
      echo 'LearnWell is installed. Open LearnWell from Applications.'
    fi
    ;;
  firmware)
    echo 'Installing Arduino Uno R3 firmware...'
    echo 'Connect one Uno R3, quit LearnWell, and close Arduino Serial Monitor/Plotter.'
    echo
    /bin/bash "${ROOT}/scripts/install_firmware.sh"
    STATUS=$?
    ;;
  *)
    echo 'Open Install LearnWell.command or Install Arduino Firmware.command.' >&2
    exit 2
    ;;
esac

if [[ ${STATUS} -ne 0 ]]; then
  echo
  echo 'Installation did not complete. See the error above for details.' >&2
fi
echo
read -r -p 'Press Return to close this installer.' _ || true
exit "${STATUS}"
