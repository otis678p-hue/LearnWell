# Environment setup

The supported build target is Apple Silicon, macOS 26+, with the macOS SDK and
Swift compiler supplied by Apple Command Line Tools. A full Xcode project is
not required. Bundle metadata and the icon are tracked, so a fresh clone does
not depend on an existing app in `build/`. Bundle assembly uses `python3`
from the development tools; the separate ML environments use Python 3.12.

## Python environments

Use Python 3.12; `.python-version` records the intended interpreter version.
Install Python separately if `python3.12` is unavailable. Then run:

```bash
bash scripts/setup_environment.sh
# Or choose an explicit interpreter:
PYTHON_BIN=/absolute/path/to/python3.12 bash scripts/setup_environment.sh
```

| Environment | Used for | Dependency files |
| --- | --- | --- |
| `.venv` | Training, classroom, export, Python checks | `environment/requirements-training-lock.txt` (captured full snapshot); `requirements-training.txt` (core pins) |
| `.venv-pose` | MediaPipe pose and face assistance | `environment/requirements-pose-lock.txt` (full resolution); `requirements-pose.txt` (core pins) |

The environments deliberately differ: the captured training environment uses
protobuf 7.36.2, while MediaPipe 0.10.20's legacy Pose API uses protobuf 4.25.9
and NumPy 1.26.4. Installing them together can cause dependency conflicts.
The pose manifest also pins JAX/JAXLIB to versions compatible with NumPy 1.x.
Setup requires internet access to install Python packages. The face-detection model
comes with the MediaPipe wheel; the app's heavy pose model is downloaded once by
setup, which then opens and runs both graphs to verify that the models load. The
MediaPipe 0.10.20 universal2 wheel carries an x86_64-only internal tag despite
including an ARM binary. The setup checker handles that specific metadata
diagnostic on ARM Macs and requires native graph inference to succeed; other
dependency errors still fail setup.

Use `bash scripts/setup_environment.sh training` or `pose` to install one
environment. Native camera classification uses the bundled CoreML model and
does not require Python. Pose assistance and training need their respective
environments. Virtual environments are recreated locally and are excluded from
the upload; copying them between machines is unreliable.

## App configuration

The app automatically looks for `.venv-pose/bin/python` beside the source tree
used to build it. Select `.venv/bin/python` under the app's training settings.
For an installed build whose source folder has moved, specify the pose Python:

```bash
defaults write com.hyacinth.notchtriage notch.pose.python -string \
  "$PWD/.venv-pose/bin/python"
```

Quit and reopen the app after changing that preference. Recreate environments
after moving the project. `environment/.env.example` documents optional shell
overrides; no API keys are required and no `.env` file is loaded automatically.

## Signing and installation

For installation from Finder, double-click **Install LearnWell.command** in the
project root. It builds the app and replaces `/Applications/LearnWell.app`.
Terminal opens automatically to display progress and waits for Return when done.
The launcher must stay beside the `scripts/` and `app/` folders.

The build uses an existing `Notch Triage Local Signing` identity when available,
or ad-hoc signing otherwise. The build never creates a signing certificate.
An optional explicit signing identity can be passed as `NOTCH_SIGNING_IDENTITY`.
The normal build writes only under `app/build/`.

To install intentionally, use `INSTALL=1 bash scripts/build.sh`; this replaces
the matching app in `/Applications`. Camera permission is granted on first use.
Distributing a notarized application is a separate release step.
