# LearnWell

LearnWell is a macOS app for comfortable study habits. It combines camera-based
posture awareness, study and break reminders, activity history, and optional
Arduino distance, temperature, and humidity readings.

## Features

- A notch interface with live posture status and configurable reminders.
- Focus and break routines, daily trends, and weekly posture heatmaps.
- Optional screen blur for posture and distance reminders.
- A native interface for importing photos, labeling datasets, training models,
  testing predictions, and exporting CoreML models.
- English and Traditional Chinese.

## Requirements

- An Apple Silicon Mac running macOS 26 or later.
- Apple Command Line Tools, installed with `xcode-select --install`.
- A camera for posture detection.
- Python 3.12 for optional pose assistance, training, and model export.

## Build and run

In Finder, double-click **Install LearnWell.command** in this folder to build
and install the app into Applications. This replaces an existing LearnWell
installation. Terminal opens automatically to show progress; you do not need to
type commands. When installation finishes, open LearnWell from Applications.
Keep the installer in this folder alongside `scripts/` and the app source.

To build and run manually instead:

From this folder:

```bash
bash scripts/build.sh
open app/build/LearnWell.app
```

The bundled CoreML model supports native detection without Python. To enable
pose assistance and training, install Python 3.12 and run:

```bash
bash scripts/setup_environment.sh
```

Select `.venv/bin/python` in the app's training settings. Training starts with an
empty photo library; import your own photos. Camera video is processed locally.
Imported training photos and activity history are stored in the user's local
Application Support directory, outside this source folder.

See [environment setup](docs/ENVIRONMENT.md), [Arduino hardware](docs/HARDWARE.md),
and [model information](docs/MODELS.md) for details.

## Quick Arduino firmware install

Connect an **Arduino Uno R3** over USB, quit LearnWell, and close Arduino Serial
Monitor/Plotter. In Finder, double-click **Install Arduino Firmware.command** in
this folder. Terminal opens automatically and shows the installation progress.

Or run the installer manually from this folder:

```bash
bash scripts/install_firmware.sh
```

This installs Arduino CLI if needed, installs the Uno core and sensor libraries,
then builds and uploads the firmware. Internet access and Python 3 are required;
Arduino IDE is optional. For clones or multiple boards, specify the USB port:

```bash
bash scripts/install_firmware.sh /dev/cu.usbmodemXXXX
```

See [Arduino hardware](docs/HARDWARE.md) for wiring and manual installation.

## Source layout

```text
app/          Swift app, localization, resources, Python workers, and build tools
models/       Posture model checkpoint
arduino/      Optional Arduino receiver firmware
environment/  Python dependency manifests and model checksums
scripts/      Setup, build, and verification commands
tests/        Python worker and firmware checks
docs/         Environment, hardware, and model reference
licenses/     Third-party licenses and notices
```

## Check the project

```bash
python3 scripts/verify_package.py
bash scripts/check.sh
```

The full checks require the training Python environment and Apple Command Line
Tools. Model inference uses a generated blank image by default. To check photos
stored outside the repository, pass their paths to
`bash app/tools/run_posture_model_check.sh /path/to/photo.jpg`.

## GitHub

Upload this folder's contents, including `.gitignore`, `.gitattributes`, and
`.python-version`. The supplied source contains no personal photos, coursework,
presentation files, local environments, build output, or development history.
The checkpoint contains inference weights and public model metadata.

The ignore rules exclude local data, credentials, environments, and generated
files. Keep any photos you import for testing outside the repository.

Third-party notices are preserved in [licenses](licenses/README.md).

## Citation

If you use LearnWell in your work, please cite the software using the metadata in
[CITATION.cff](CITATION.cff). The citation credits LearnWell contributors without
including personal contact information.
