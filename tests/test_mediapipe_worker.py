"""Binary worker protocol and face-only/multiple-person regression checks."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

import cv2
import numpy as np

SCRIPT = Path(__file__).resolve().parents[1] / "app/Bridge/mediapipe_pose.py"
spec = importlib.util.spec_from_file_location("mediapipe_worker", SCRIPT)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def packet(self, data=b"jpeg", frame_id=12):
        return worker.HEADER.pack(b"PMJ1", frame_id, len(data)) + data

    def test_frame_boundaries_and_eof(self):
        stream = io.BytesIO(self.packet(b"one") + self.packet(b"two", 13))
        self.assertEqual(worker.read_frame(stream), (12, b"one"))
        self.assertEqual(worker.read_frame(stream), (13, b"two"))
        self.assertIsNone(worker.read_frame(stream))

    def test_partial_and_oversized_frames_are_rejected(self):
        for data in [b"PM", self.packet()[:-1]]:
            with self.assertRaises(EOFError):
                worker.read_frame(io.BytesIO(data))
        for header in [worker.HEADER.pack(b"BAD!", 1, 4),
                       worker.HEADER.pack(b"PMJ1", 1, worker.MAX_IMAGE_BYTES + 1)]:
            with self.assertRaises(ValueError):
                worker.read_frame(io.BytesIO(header))

    def run_frame(self, face_count=0, points=None, data=None):
        image = np.full((32, 32, 3), (255, 0, 0), dtype=np.uint8)
        jpeg = cv2.imencode(".jpg", image)[1].tobytes() if data is None else data
        face = SimpleNamespace(location_data=SimpleNamespace(relative_bounding_box=
            SimpleNamespace(xmin=0.4, ymin=0.2, width=0.2, height=0.3)))
        faces = SimpleNamespace(process=lambda _: SimpleNamespace(detections=[face] * face_count))

        def process(rgb):
            self.assertGreater(int(rgb[16, 16, 2]), 250, "BGR must be converted to RGB")
            return SimpleNamespace(pose_landmarks=SimpleNamespace(landmark=points) if points else None)

        pose = SimpleNamespace(process=process)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = worker.serve(io.BytesIO(self.packet(jpeg)), pose, faces, cv2, np)
        return status, json.loads(output.getvalue())

    def test_face_without_pose_remains_a_valid_locating_result(self):
        status, result = self.run_frame(face_count=1)
        self.assertEqual(status, 0)
        self.assertEqual(result["body_count"], 1)
        self.assertEqual(result["landmarks"], [])
        self.assertAlmostEqual(result["face_box"][2], 0.2)
        self.assertNotIn("error", result)

    def test_multiple_faces_suppress_single_person_landmarks(self):
        points = [SimpleNamespace(x=0.5, y=0.4, z=0.0, visibility=0.9)] * 33
        _, result = self.run_frame(face_count=2, points=points)
        self.assertEqual(result["body_count"], 2)
        self.assertEqual(result["landmarks"], [])

    def test_heavy_model_only_when_already_installed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            fake_mp = SimpleNamespace(__file__=str(Path(folder) / "__init__.py"))
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(worker.model_complexity(fake_mp), 1)
            heavy = Path(folder) / "modules/pose_landmark/pose_landmark_heavy.tflite"
            heavy.parent.mkdir(parents=True)
            heavy.write_bytes(b"model")
            self.assertEqual(worker.model_complexity(fake_mp), 2)

    def test_invalid_image_returns_matching_error_and_stops_tracking(self):
        status, result = self.run_frame(data=b"broken")
        self.assertEqual(status, 1)
        self.assertEqual(result["id"], 12)
        self.assertIn("error", result)


if __name__ == "__main__":
    unittest.main()
