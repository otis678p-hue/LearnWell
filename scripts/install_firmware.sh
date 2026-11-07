#!/bin/bash
# Install the tools and upload LearnWell firmware to an Arduino Uno R3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo 'Usage: bash scripts/install_firmware.sh [USB_PORT]'
  echo 'Connect an Arduino Uno R3 and close LearnWell and Arduino Serial Monitor first.'
  echo 'Without USB_PORT, exactly one recognized Uno must be connected.'
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
  usage >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'Python 3 is required for USB board detection. Install Apple Command Line Tools or Python 3.' >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CLI="$(command -v arduino-cli || true)"
if [[ -z "${CLI}" ]]; then
  BIN_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/learnwell/arduino-cli"
  CLI="${BIN_DIR}/arduino-cli"
  if [[ ! -x "${CLI}" ]]; then
    echo 'Installing Arduino CLI...'
    mkdir -p "${BIN_DIR}"
    # Official installer: https://docs.arduino.cc/arduino-cli/installation
    curl -fsSL --retry 3 https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
      -o "${WORK}/install-arduino-cli.sh"
    BINDIR="${BIN_DIR}" sh "${WORK}/install-arduino-cli.sh"
  fi
fi

echo 'Installing Uno support and sensor libraries...'
"${CLI}" core update-index
"${CLI}" core install arduino:avr
"${CLI}" lib update-index
"${CLI}" lib install 'DHT sensor library' 'Adafruit Unified Sensor'

PORT="${1:-}"
if [[ -z "${PORT}" ]]; then
  "${CLI}" board list --json > "${WORK}/boards.json"
  PORT="$(python3 - "${WORK}/boards.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    result = json.load(source)
# Older CLI releases returned a list; current releases wrap detected_ports.
boards = result if isinstance(result, list) else result.get("detected_ports", [])
ports = sorted({
    board["port"]["address"]
    for board in boards
    if board.get("port", {}).get("protocol") == "serial"
    and any(match.get("fqbn") == "arduino:avr:uno"
            for match in board.get("matching_boards", []))
})
if len(ports) != 1:
    print("Connect exactly one Arduino Uno R3, or specify its USB port:", file=sys.stderr)
    print("  bash scripts/install_firmware.sh /dev/cu.usbmodemXXXX", file=sys.stderr)
    print("Detected serial ports:", file=sys.stderr)
    for board in boards:
        port = board.get("port", {})
        if port.get("protocol") == "serial":
            print("  " + port["address"], file=sys.stderr)
    if not boards:
        print("  None. Check the USB data cable and reconnect the board.", file=sys.stderr)
    sys.exit(1)
print(ports[0])
PY
)"
fi

echo "Building firmware for Arduino Uno R3..."
"${CLI}" compile --fqbn arduino:avr:uno --build-path "${WORK}/build" \
  "${ROOT}/arduino/PostureReceiver"
echo "Uploading firmware to ${PORT}..."
if ! "${CLI}" upload --fqbn arduino:avr:uno --port "${PORT}" \
  --input-dir "${WORK}/build" "${ROOT}/arduino/PostureReceiver"; then
  echo 'Upload failed. Close LearnWell and Serial Monitor, check the USB port/cable, then retry.' >&2
  exit 1
fi
echo 'Firmware installed. Open LearnWell and enable the Arduino connection.'
