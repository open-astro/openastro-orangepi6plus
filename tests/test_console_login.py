"""Test the setup's factory-autologin cleanup without touching host units."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SETUP = Path(__file__).resolve().parents[1] / "openastro/openastro-setup.sh"
CLEANUP = SETUP.read_text().split(
    "# Remove factory root autologin normally retired by the skipped wizard.\n"
)[1].split("\n\n")[0]
UNITS = ["getty@", "getty@tty1", "serial-getty@", "serial-getty@ttyGS0"]


class ConsoleLoginTests(unittest.TestCase):
    def run_cleanup(self, directory):
        script = CLEANUP.replace("/etc/systemd/system/", directory + "/")
        subprocess.run(
            ["bash", "-eu", "-c", 'systemctl() { return 0; }\n' + script],
            check=True, env={"PATH": os.environ["PATH"]},
        )

    def test_factory_root_autologin_removed_and_rerun_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for unit in UNITS:
                path = Path(directory) / f"{unit}.service.d/override.conf"
                path.parent.mkdir()
                path.write_text("[Service]\nExecStart=\nExecStart=-/sbin/agetty --noissue --autologin root %I $TERM\n")
                paths.append(path)
            self.run_cleanup(directory)
            self.run_cleanup(directory)
            self.assertTrue(all(not path.exists() for path in paths))

    def test_unrelated_override_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "getty@.service.d/override.conf"
            path.parent.mkdir()
            content = "[Service]\nTTYVTDisallocate=no\n"
            path.write_text(content)
            self.run_cleanup(directory)
            self.assertEqual(path.read_text(), content)
