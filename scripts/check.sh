#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${POSTURE_TEST_PYTHON:-${ROOT}/.venv/bin/python}"
python3 "${ROOT}/scripts/verify_package.py"
python3 -B -m unittest discover -s "${ROOT}/tests" -p 'test_install_firmware.py' -v
"${PYTHON}" -m unittest discover -s "${ROOT}/tests" -p 'test_mediapipe_worker.py' -v
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
c++ -std=c++17 -I "${ROOT}/tests/arduino_stubs" "${ROOT}/tests/test_firmware.cpp" -o "${WORK}/firmware-check"
"${WORK}/firmware-check"
bash "${ROOT}/app/tools/run_posture_logic_check.sh"
bash "${ROOT}/app/tools/run_posture_model_check.sh"
swiftc -O -parse-as-library "${ROOT}/app/tools/check_localization.swift" -o "${WORK}/localization-check"
"${WORK}/localization-check" "${ROOT}/app"
