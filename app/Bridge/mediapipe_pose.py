#!/usr/bin/env python3
"""Local, persistent pose worker. Receives JPEG frames; never opens a camera.

stdin: 12-byte network-order header (!4sII: PMJ1, frame id, JPEG byte count),
       followed by that many JPEG bytes.
stdout: one JSON ready message, then one JSON result per frame. All logs use stderr.
No images are written to disk and no network service is started.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import struct
import sys

HEADER = struct.Struct("!4sII")
MAX_IMAGE_BYTES = 8 * 1024 * 1024


def read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            if not result:
                return None
            raise EOFError("incomplete frame")
        result.extend(chunk)
    return bytes(result)


def read_frame(stream):
    header = read_exact(stream, HEADER.size)
    if header is None:
        return None
    magic, frame_id, size = HEADER.unpack(header)
    if magic != b"PMJ1" or not 0 < size <= MAX_IMAGE_BYTES:
        raise ValueError("invalid frame header")
    data = read_exact(stream, size)
    if data is None:
        raise EOFError("missing frame")
    return frame_id, data


def emit(message):
    print(json.dumps(dict(version=1, **message), allow_nan=False, separators=(",", ":")), flush=True)


def load_dependencies(libraries):
    os.environ.setdefault("GLOG_minloglevel", "2")
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    # Explicit workspace library path, with a development fallback for this checkout.
    candidates = [Path(libraries)] if libraries else []
    candidates.append(Path(__file__).resolve().parents[2] / "vendor" / "pylibs")
    for path in candidates:
        if path.is_dir():
            sys.path.insert(0, str(path))
            break
    with contextlib.redirect_stdout(sys.stderr):
        import cv2
        import numpy as np
        import mediapipe as mp
    if not hasattr(mp, "solutions"):
        raise RuntimeError("This worker needs MediaPipe 0.10.20 (legacy Pose API).")
    return cv2, np, mp


def model_complexity(mp):
    """Heavy model (2) when setup has downloaded it, else the bundled full model (1).

    The app analyses only ~5 frames/s, so the heavy model is affordable. The legacy
    API would otherwise download it here, inside the app's start-up timeout, and an
    interrupted download leaves a truncated file that is never fetched again.
    """
    heavy = Path(mp.__file__).parent / "modules/pose_landmark/pose_landmark_heavy.tflite"
    if heavy.is_file():
        return 2
    print("Heavy pose model missing; using the standard model. "
          "Run scripts/setup_environment.sh pose to install it.", file=sys.stderr)
    return 1


def serve(stream, pose, faces, cv2, np):
    while (frame := read_frame(stream)) is not None:
        frame_id, data = frame
        try:
            image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
            if image is None or max(image.shape[:2]) > 2048:
                raise ValueError("invalid image")
            rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
            rgb.flags.writeable = False
            with contextlib.redirect_stdout(sys.stderr):
                detected_faces = faces.process(rgb).detections or []
                face_count = len(detected_faces)
                result = pose.process(rgb)
            landmarks = result.pose_landmarks.landmark if result.pose_landmarks else []
            # Legacy Pose tracks only one body. A separate face detector rejects
            # obvious multi-person frames; YOLO's multi-person gate remains in Swift.
            count = max(face_count, int(bool(landmarks)))
            face_box = None
            if face_count == 1:
                box = detected_faces[0].location_data.relative_bounding_box
                x, y = max(0.0, box.xmin), max(0.0, box.ymin)
                right, bottom = min(1.0, box.xmin + box.width), min(1.0, box.ymin + box.height)
                if right > x and bottom > y:
                    face_box = [x, y, right - x, bottom - y]
            emit(dict(id=frame_id, body_count=count, face_box=face_box, landmarks=[
                dict(x=p.x, y=p.y, z=p.z, visibility=p.visibility) for p in landmarks
            ] if count == 1 else []))
        except Exception as exc:
            emit(dict(id=frame_id, error=str(exc)))
            # A failed graph must not supply tracking state to the next frame.
            return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libraries", help="Directory containing the pinned MediaPipe package")
    args = parser.parse_args()
    try:
        cv2, np, mp = load_dependencies(args.libraries)
        complexity = model_complexity(mp)
        with contextlib.redirect_stdout(sys.stderr):
            # No smoothing: the legacy API assumes ~30 fps timestamps, so its filter
            # lags at 5 fps; Swift already averages the verdict over frames.
            pose = mp.solutions.pose.Pose(
                static_image_mode=False, model_complexity=complexity, smooth_landmarks=False,
                enable_segmentation=False, min_detection_confidence=0.5,
                min_tracking_confidence=0.5,
            )
            faces = mp.solutions.face_detection.FaceDetection(min_detection_confidence=0.5)
    except Exception as exc:
        emit(dict(ready=False, error=str(exc)))
        return 1
    try:
        emit(dict(ready=True, backend="mediapipe", mediapipe_version=mp.__version__))
        return serve(sys.stdin.buffer, pose, faces, cv2, np)
    except (EOFError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        with contextlib.redirect_stdout(sys.stderr):
            pose.close()
            faces.close()


if __name__ == "__main__":
    raise SystemExit(main())
