#!/usr/bin/env python3
"""Backend for the YOLO Classroom app.

The GUI owns everything a student can edit (folders, labels, data.yaml). This
script only does the parts that need Ultralytics: fine-tune, test, export.

All machine-readable output goes over stdout as "@yolo-classroom <json>" lines;
plain training output is forwarded as log events so the app can show a real log
without tqdm carriage-return noise.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import time
import traceback

PREFIX = "@yolo-classroom "
FORMATS = {
    "coreml": "coreml",
    "onnx": "onnx",
    "torchscript": "torchscript",
    "rknn": "rknn",
}


# The real stdout stays reachable while training output is redirected, so
# events never recurse through the LineWriter below.
REAL_STDOUT = sys.stdout
NL = chr(10)


def event(kind: str, **values) -> None:
    line = PREFIX + json.dumps({"kind": kind, **values}, ensure_ascii=False)
    REAL_STDOUT.write(line + NL)
    REAL_STDOUT.flush()


class LineWriter(io.TextIOBase):
    """Turns streaming writes (including tqdm carriage returns) into log lines."""

    def __init__(self) -> None:
        self.buffer = ""

    def write(self, chunk: str) -> int:  # type: ignore[override]
        self.buffer += chunk
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            line = line.replace("\r", " ").strip()
            if line:
                event("log", text=line)
        return len(chunk)

    def flush(self) -> None:  # type: ignore[override]
        line = self.buffer.replace("\r", " ").strip()
        self.buffer = ""
        if line:
            event("log", text=line)


def pick_device(requested: str) -> str:
    if requested and requested != "auto":
        return requested
    import torch

    if torch.cuda.is_available():
        return "0"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def numeric(value) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return float("nan")


def train(args: argparse.Namespace) -> None:
    from ultralytics import YOLO

    data = Path(args.data).expanduser().resolve()
    weights = Path(args.model).expanduser().resolve()
    project = Path(args.project).expanduser().resolve()
    run_dir = project / args.name
    project.mkdir(parents=True, exist_ok=True)

    if not data.is_file():
        raise SystemExit(f"missing dataset yaml: {data}")
    if not weights.is_file():
        raise SystemExit(f"missing starting weights: {weights}")

    device = pick_device(args.device)
    try:
        batch: int | float = int(args.batch)
    except (TypeError, ValueError):
        try:
            batch = float(args.batch)
        except (TypeError, ValueError):
            batch = 4
    model = YOLO(str(weights))
    started = time.time()
    history: list[dict] = []
    latest: dict = {}

    def on_start(trainer) -> None:
        event(
            "start",
            epochs=int(trainer.epochs),
            imgsz=int(trainer.args.imgsz),
            device=str(device),
            model=weights.name,
            run=str(run_dir),
        )

    def on_train_epoch_end(trainer) -> None:
        losses = {}
        items = getattr(trainer, "loss_items", None)
        names = list(getattr(trainer, "loss_names", []) or [])
        if isinstance(items, dict):
            losses = {str(key): float(value) for key, value in items.items()}
        elif items is not None:
            for index, value in enumerate(items.detach().cpu().tolist()):
                key = names[index] if index < len(names) else f"loss{index + 1}"
                losses[str(key)] = float(value)
        elapsed = time.time() - started
        epoch = int(trainer.epoch) + 1
        done = max(epoch, 1)
        event(
            "epoch",
            epoch=epoch,
            epochs=int(trainer.epochs),
            losses=losses,
            elapsed=round(elapsed, 2),
            eta=round(elapsed / done * max(int(trainer.epochs) - epoch, 0), 1),
        )

    def on_fit_epoch_end(trainer) -> None:
        metrics = getattr(trainer, "metrics", None) or {}
        payload = {}
        for key, value in metrics.items():
            if isinstance(value, (int, float)):
                payload[str(key)] = float(value)
        latest.update(payload)
        epoch = int(trainer.epoch) + 1
        history.append(
            {
                "epoch": epoch,
                "metrics": payload,
                "losses": {},
            }
        )
        event("metrics", epoch=epoch, metrics=payload)

    def on_train_end(trainer) -> None:
        best = getattr(trainer, "best", None) or (run_dir / "weights" / "best.pt")
        best_path = Path(str(best))
        summary = {
            "name": args.name,
            "epochs": int(trainer.epochs),
            "imgsz": int(trainer.args.imgsz),
            "batch": str(trainer.args.batch),
            "device": str(device),
            "model": weights.name,
            "dataset": str(data),
            "seconds": round(time.time() - started, 1),
            "best": str(best_path),
            "metrics": latest,
            "finishedAt": time.strftime("%Y-%m-%d %H:%M"),
        }
        try:
            (run_dir / "classroom.json").write_text(
                json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except OSError:
            pass
        event("done", **summary)

    model.add_callback("on_train_start", on_start)
    model.add_callback("on_train_epoch_end", on_train_epoch_end)
    model.add_callback("on_fit_epoch_end", on_fit_epoch_end)
    model.add_callback("on_train_end", on_train_end)

    stream = LineWriter()
    with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
        model.train(
            data=str(data),
            epochs=int(args.epochs),
            imgsz=int(args.imgsz),
            batch=batch,
            device=device,
            project=str(project),
            name=args.name,
            exist_ok=True,
            workers=0,
            plots=False,
            verbose=False,
            seed=0,
            patience=int(args.patience),
            val=True,
        )
    stream.flush()


def test(args: argparse.Namespace) -> None:
    from ultralytics import YOLO

    weights = Path(args.weights).expanduser().resolve()
    source = Path(args.source).expanduser().resolve()
    if not weights.is_file():
        raise SystemExit(f"missing weights: {weights}")
    if not source.is_file():
        raise SystemExit(f"missing image: {source}")

    model = YOLO(str(weights))
    results = model.predict(
        source=str(source),
        conf=float(args.conf),
        imgsz=int(args.imgsz),
        device=pick_device(args.device),
        verbose=False,
    )
    boxes = []
    height, width = 0, 0
    if results:
        result = results[0]
        height, width = int(result.orig_shape[0]), int(result.orig_shape[1])
        names = result.names
        for box in result.boxes:
            x1, y1, x2, y2 = [float(v) for v in box.xyxy[0].tolist()]
            boxes.append(
                {
                    "label": str(names[int(box.cls[0])]),
                    "conf": float(box.conf[0]),
                    "x1": x1,
                    "y1": y1,
                    "x2": x2,
                    "y2": y2,
                }
            )
    event("detections", boxes=boxes, width=width, height=height, image=str(source))


def export(args: argparse.Namespace) -> None:
    from ultralytics import YOLO

    weights = Path(args.weights).expanduser().resolve()
    if not weights.is_file():
        raise SystemExit(f"missing weights: {weights}")
    fmt = FORMATS[args.format]
    device = pick_device(args.device)

    stream = LineWriter()
    with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
        model = YOLO(str(weights))
        produced = model.export(
            format=fmt,
            half=bool(args.half),
            imgsz=int(args.imgsz),
            device=device,
        )
    stream.flush()
    event("export", format=args.format, path=str(produced))


def check(_args: argparse.Namespace) -> None:
    import importlib

    def version(name: str):
        try:
            module = importlib.import_module(name)
        except Exception:
            return None
        return str(getattr(module, "__version__", "ok"))

    import torch

    event(
        "check",
        ultralytics=version("ultralytics"),
        torch=version("torch"),
        coremltools=version("coremltools"),
        onnx=version("onnx"),
        rknn=version("rknn.api") or version("rknn"),
        mps=bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()),
        cuda=bool(torch.cuda.is_available()),
        device=pick_device("auto"),
        python=sys.version.split()[0],
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["train", "test", "export", "check"])
    parser.add_argument("--data")
    parser.add_argument("--model")
    parser.add_argument("--weights")
    parser.add_argument("--source")
    parser.add_argument("--project")
    parser.add_argument("--name", default="exp")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", default="4")
    parser.add_argument("--patience", type=int, default=15)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--conf", type=float, default=0.25)
    parser.add_argument("--format", choices=sorted(FORMATS), default="coreml")
    parser.add_argument("--half", action="store_true")
    args = parser.parse_args()

    os.environ.setdefault("YOLO_VERBOSE", "False")
    os.environ.setdefault("MPLBACKEND", "Agg")

    try:
        {"train": train, "test": test, "export": export, "check": check}[args.action](args)
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 - the GUI shows whatever happened
        event("error", message=f"{type(exc).__name__}: {exc}")
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
