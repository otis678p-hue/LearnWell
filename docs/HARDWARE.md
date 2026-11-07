# Optional Arduino Uno R3

## Quick firmware install

Connect the Uno R3 with a USB data cable. Quit LearnWell and close Arduino
Serial Monitor/Plotter so the uploader can access the board. In Finder,
double-click **Install Arduino Firmware.command** in the repository root.
Terminal opens automatically to show progress; no commands need to be typed.
Keep the launcher in the project folder. Press Return after it finishes.

To run the same installer manually, use:

```bash
bash scripts/install_firmware.sh
```

The command downloads Arduino CLI if needed, installs the `arduino:avr` core,
**DHT sensor library**, and **Adafruit Unified Sensor**, then compiles and uploads
`PostureReceiver`. It requires internet access and Python 3; it does not require
Arduino IDE or administrator privileges. Downloaded CLI binaries are cached in
`${XDG_CACHE_HOME:-$HOME/.cache}/learnwell/arduino-cli`; cores and libraries use
your Arduino CLI configuration and default Arduino directories.

Automatic detection requires exactly one recognized Uno R3. For an unrecognized
Uno clone or multiple boards, use the board's serial port shown by the command:

```bash
bash scripts/install_firmware.sh /dev/cu.usbmodemXXXX
```

Replace the example port with your board's actual port (some clones use
`/dev/cu.usbserial-*`). The command targets Uno R3, including when a port is
specified. After upload, open LearnWell and enable its Arduino connection.

## Arduino IDE alternative

Open `arduino/PostureReceiver/PostureReceiver.ino` in Arduino IDE and select
Arduino Uno. Install the **DHT sensor library by Adafruit** and its dependency
**Adafruit Unified Sensor** through Library Manager before compiling.

## Wiring

| Device | Uno pin |
| --- | --- |
| HC-SR04 trigger | D8 |
| HC-SR04 echo | D9 |
| External red LED (through a resistor) | D7 |
| DHT11 signal | D2 |

Connect sensor power and grounds as appropriate for their modules. The firmware
defaults to DHT11; change `POSTURE_DHT_TYPE` to DHT22 for that sensor.
Upload the sketch, close Serial Monitor/Plotter, and connect the board over USB.
The macOS app discovers supported USB boards and reads serial at 115200 baud.
Distance below 50 cm or a bad-posture signal lights the red LED. Camera posture
detection works independently of the board.
