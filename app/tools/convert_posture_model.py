#!/usr/bin/env python3
"""Convert the SittingPosture YOLO26n weights to the CoreML model LearnWell runs.

The exported graph keeps the YOLO26 detect head, so CoreML returns the raw
`(1, 6, 8400)` tensor: rows of (cx, cy, w, h, bad, good) in the pixels of the
640 x 640 letterboxed input. YOLO26 is anchor-free and has no objectness channel,
and the two class scores arrive already sigmoid-applied, so the Swift decoder in
`Sources/PostureClassifier.swift` only has to threshold and run NMS.

The input stays a square 640 x 640 canvas because that is what the weights were
trained on (ultralytics letterbox); the old YOLOv5 model wanted the 640 x 384
minimum rectangle of a 16:9 frame instead.

Usage:
    pip install ultralytics coremltools
    python tools/convert_posture_model.py ../models/sitting_posture_yolo26n.pt \
        build/PostureYOLO.mlpackage [width height]
Then compile the package for the app bundle (works without a full Xcode install):
    swift tools/compile_posture_model.swift build/PostureYOLO.mlpackage Sources/PostureYOLO.mlmodelc
"""
import json
import shutil
import sys
import tempfile
from pathlib import Path

EXPECTED_LABELS = {0: "Bad", 1: "Good"}


def export(weights: Path, work: Path, width: int, height: int, quantize: int | None) -> Path:
    """Run the ultralytics CoreML export inside `work` and return the .mlpackage."""
    from ultralytics import YOLO

    local = work / "sitting_posture_yolo26n.pt"
    shutil.copy2(weights, local)
    model = YOLO(str(local))
    names = {int(key): str(value) for key, value in model.names.items()}
    if names != EXPECTED_LABELS:
        raise SystemExit(f"unexpected labels {names}, expected {EXPECTED_LABELS}")
    # nms=None keeps the raw head: Notch Triage does its own threshold + NMS.
    model.export(
        format="coreml",
        imgsz=(height, width),
        nms=None,
        quantize=quantize,
        device="cpu",
    )
    produced = sorted(work.glob("*.mlpackage"))
    if len(produced) != 1:
        raise SystemExit(f"expected one .mlpackage in {work}, found {produced}")
    return produced[0]


def describe(package: Path) -> dict:
    import coremltools as ct

    spec = ct.models.MLModel(str(package)).get_spec()
    inputs = [
        {"name": item.name, "width": item.type.imageType.width, "height": item.type.imageType.height}
        for item in spec.description.input
    ]
    outputs = [
        {"name": item.name, "shape": [int(dim) for dim in item.type.multiArrayType.shape]}
        for item in spec.description.output
    ]
    return {"inputs": inputs, "outputs": outputs}


def main() -> None:
    if len(sys.argv) not in (3, 5):
        raise SystemExit(__doc__)
    weights = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    width = int(sys.argv[3]) if len(sys.argv) > 3 else 640
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 640
    if not weights.is_file():
        raise SystemExit(f"missing weights: {weights}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        package = export(weights, Path(work), width, height, quantize=16)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(package, destination)
    print(json.dumps(
        {"saved": str(destination), "labels": EXPECTED_LABELS, **describe(destination)},
        indent=1,
    ))


if __name__ == "__main__":
    main()
