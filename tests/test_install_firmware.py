"""Exercise the installer without downloading tools or flashing hardware."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/install_firmware.sh"


def board(address, fqbn="arduino:avr:uno"):
    return {"port": {"address": address, "protocol": "serial"},
            "matching_boards": [{"fqbn": fqbn}] if fqbn else []}


class FirmwareInstallTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin",
                        HOME=str(self.root), XDG_CACHE_HOME=str(self.root / "cache"),
                        CLI_LOG=str(self.log), BOARDS=json.dumps({"detected_ports": [
                            board("/dev/cu.test-uno")]}), FAIL_COMMAND="")
        (self.bin / "python3").symlink_to(sys.executable)
        self.cli = self.bin / "arduino-cli"
        self.cli.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
with open(os.environ["CLI_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == os.environ.get("FAIL_COMMAND"):
    sys.exit(1)
if sys.argv[1:3] == ["board", "list"]:
    print(os.environ["BOARDS"])
''')
        self.cli.chmod(0o755)

    def run_installer(self, *args):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *args], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] \
            if self.log.exists() else []
        return result, calls

    def test_detects_uno_builds_then_uploads_and_cleans_build(self):
        self.env["BOARDS"] = json.dumps({"detected_ports": [
            board("/dev/cu.other", "arduino:avr:mega"), board("/dev/cu.test-uno")]})
        result, calls = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["lib", "install", "DHT sensor library", "Adafruit Unified Sensor"], calls)
        compile_call, upload_call = calls[-2:]
        self.assertEqual(compile_call[:3], ["compile", "--fqbn", "arduino:avr:uno"])
        self.assertEqual(upload_call[:5], ["upload", "--fqbn", "arduino:avr:uno",
                                          "--port", "/dev/cu.test-uno"])
        build = compile_call[compile_call.index("--build-path") + 1]
        self.assertEqual(upload_call[upload_call.index("--input-dir") + 1], build)
        self.assertFalse(Path(build).parent.exists())

    def test_no_uno_or_ambiguous_unos_do_not_flash(self):
        for boards in ([], [board("/dev/cu.clone", None)],
                       [board("/dev/cu.one"), board("/dev/cu.two")]):
            with self.subTest(boards=boards):
                self.env["BOARDS"] = json.dumps({"detected_ports": boards})
                result, calls = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("specify its USB port", result.stderr)
                self.assertFalse(any(call[0] in ("compile", "upload") for call in calls))

    def test_explicit_clone_port_skips_detection(self):
        result, calls = self.run_installer("/dev/cu.usbserial-clone")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "board" for call in calls))
        self.assertIn("/dev/cu.usbserial-clone", calls[-1])

    def test_compile_failure_does_not_upload(self):
        self.env["FAIL_COMMAND"] = "compile"
        result, calls = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "upload" for call in calls))

    def test_upload_failure_is_reported(self):
        self.env["FAIL_COMMAND"] = "upload"
        result, _ = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Upload failed", result.stderr)
        self.assertNotIn("Firmware installed", result.stdout)

    def test_bootstraps_missing_cli(self):
        source = self.root / "mock-cli"
        self.cli.rename(source)
        self.env["MOCK_CLI"] = str(source)
        curl = self.bin / "curl"
        curl.write_text('''#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then
    cat > "$2" <<'INSTALLER'
cp "$MOCK_CLI" "$BINDIR/arduino-cli"
INSTALLER
    exit 0
  fi
  shift
done
exit 1
''')
        curl.chmod(0o755)
        result, calls = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "cache/learnwell/arduino-cli/arduino-cli").is_file())
        self.assertEqual(calls[-1][0], "upload")

    def test_help_and_invalid_arguments_do_not_install(self):
        for args, expected in ((["--help"], 0), (["--invalid"], 2), (["a", "b"], 2)):
            with self.subTest(args=args):
                result, calls = self.run_installer(*args)
                self.assertEqual(result.returncode, expected)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
