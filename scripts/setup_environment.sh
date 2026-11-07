#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON_BIN:-python3.12}"
MODE="${1:-all}"
case "${MODE}" in all|training|pose) ;; *) echo 'Usage: setup_environment.sh [all|training|pose]' >&2; exit 2;; esac
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo 'Python 3.12 is required. Install it first, or set PYTHON_BIN to its executable.' >&2
  exit 1
fi
"${PYTHON}" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Use Python 3.12"'
if [[ "${MODE}" != pose ]]; then
  "${PYTHON}" -m venv "${ROOT}/.venv"
  "${ROOT}/.venv/bin/python" -m pip install -r "${ROOT}/environment/requirements-training-lock.txt"
  "${ROOT}/.venv/bin/python" -m pip check
  "${ROOT}/.venv/bin/python" -c 'import torch, cv2, yaml, ultralytics, coremltools; print("Training dependencies ready")'
fi
if [[ "${MODE}" != training ]]; then
  "${PYTHON}" -m venv "${ROOT}/.venv-pose"
  "${ROOT}/.venv-pose/bin/python" -m pip install -r "${ROOT}/environment/requirements-pose-lock.txt"
  "${ROOT}/.venv-pose/bin/python" -u "${ROOT}/scripts/check_pose_environment.py"
fi
echo 'Environment setup complete. Build the app with: bash scripts/build.sh'
