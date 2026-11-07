#!/usr/bin/env python3
"""Check dependencies and load native pose/face graphs on the installed runtime."""
import platform
import subprocess
import sys

check = subprocess.run([sys.executable, "-m", "pip", "check"], capture_output=True, text=True)
lines = (check.stdout + check.stderr).splitlines()
# The 0.10.20 universal2 wheel contains native arm64 code but its internal WHEEL
# metadata says x86_64. Accept only that exact tag diagnostic, then load and run
# both graphs below. All other dependency failures still abort setup.
tag_message = "mediapipe 0.10.20 is not supported on this platform"
known_tag = sys.platform == "darwin" and platform.machine() == "arm64"
errors = [line for line in lines if line != "No broken requirements found." and
          not (known_tag and line == tag_message)]
if check.returncode and (errors or not (known_tag and tag_message in lines)):
    raise SystemExit("\n".join(errors) or "Dependency verification failed")

print("Loading MediaPipe pose and face graphs…", flush=True)
import mediapipe as mp
import numpy as np

assert mp.__version__ == "0.10.20" and hasattr(mp, "solutions"), "Legacy Pose API required"
frame = np.zeros((64, 64, 3), dtype=np.uint8)
# The app uses the heavy model, which the legacy API downloads on first use. Fetch
# it here so the app's first start does not wait on the network.
with mp.solutions.pose.Pose(model_complexity=2) as pose:
    pose.process(frame)
with mp.solutions.face_detection.FaceDetection() as faces:
    faces.process(frame)
print("Pose dependencies, native runtime, and model assets ready")
