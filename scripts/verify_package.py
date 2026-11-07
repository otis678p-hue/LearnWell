#!/usr/bin/env python3
"""Check required source files, portable model assets, and upload exclusions."""
from pathlib import Path
import hashlib
import json
import re
import sys
import zipfile
import pickletools

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {".git", ".venv", ".venv-pose", "__pycache__", ".cache", "build", ".build", "release"}
REQUIRED = (
    "Install LearnWell.command", "Install Arduino Firmware.command", "scripts/run_installer.sh",
    "README.md", ".gitignore", ".gitattributes", ".python-version",
    "environment/requirements-training.txt", "environment/requirements-training-lock.txt",
    "environment/requirements-pose.txt", "environment/requirements-pose-lock.txt",
    "environment/model-manifest.json", "app/Config/BundleInfo.plist",
    "app/Config/AppInfo.plist", "app/Resources/AppIcon.icns",
    "app/Sources/en.lproj/InfoPlist.strings", "app/Sources/zh-Hant.lproj/InfoPlist.strings",
    "app/Bridge/mediapipe_pose.py", "app/Bridge/yolo_classroom.py",
    "app/tools/build_app.sh", "app/tools/convert_posture_model.py",
    "scripts/check_pose_environment.py", "scripts/install_firmware.sh",
    "arduino/PostureReceiver/PostureReceiver.ino",
    "licenses/AGPL-3.0.txt", "licenses/APACHE-2.0.txt", "licenses/DORSO-MIT.txt",
)
PRIVATE_PATH = re.compile(r"(?:/(?:Users|home)/[^/\s]+|(?<![A-Za-z0-9])[A-Za-z]:[\\/])")


def main():
    errors = []
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            errors.append(f"Missing required file: {name}")
    manifest_path = ROOT / "environment/model-manifest.json"
    if manifest_path.is_file():
        for item in json.loads(manifest_path.read_text())["files"]:
            path = ROOT / item["path"]
            if not path.is_file():
                errors.append(f"Missing model asset: {item['path']}")
            elif (path.stat().st_size != item["bytes"] or
                  hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]):
                errors.append(f"Model bytes differ from manifest: {item['path']}")
    count = total = 0
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if any(part in IGNORED for part in relative.parts):
            continue
        if path.is_symlink():
            errors.append(f"Symlink is not portable: {relative}")
        elif path.is_file():
            count += 1
            total += path.stat().st_size
            if path.stat().st_size > 25 * 1024 * 1024:
                errors.append(f"File exceeds the 25 MiB upload budget: {relative}")
            if (path.name == ".DS_Store" or path.suffix.lower() in
                    {".pyc", ".p12", ".pfx", ".pem", ".key", ".jpg", ".jpeg", ".heic",
                     ".mp4", ".mov", ".docx", ".pptx", ".log"}):
                errors.append(f"Private or generated file should not be uploaded: {relative}")
            if path.name.startswith(".env") and path.name != ".env.example":
                errors.append(f"Local environment settings should not be uploaded: {relative}")
            try:
                contents = path.read_text()
            except (UnicodeDecodeError, ValueError):
                continue
            if PRIVATE_PATH.search(contents):
                errors.append(f"Machine-specific path found: {relative}")
    checkpoint = ROOT / "models/sitting_posture_yolo26n.pt"
    if checkpoint.is_file():
        # Inspect strings without executing the checkpoint's pickle.
        with zipfile.ZipFile(checkpoint) as archive:
            for name in archive.namelist():
                if name.endswith("data.pkl"):
                    for _, argument, _ in pickletools.genops(archive.read(name)):
                        if isinstance(argument, str) and PRIVATE_PATH.search(argument):
                            errors.append("Machine-specific path found in model metadata")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Package verified: {count} files, {total / 1024**2:.1f} MiB; model checksums match.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
