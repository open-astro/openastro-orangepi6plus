"""Exercise the builder's actual fstab edit without root or loop devices."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

LIBRARY = Path(__file__).resolve().parents[1] / "build/uefi-image.sh"


class ImageFstabTests(unittest.TestCase):
    def test_replace_both_uuids_without_changing_other_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            fstab = Path(directory) / "etc/fstab"
            fstab.parent.mkdir()
            fstab.write_text(
                "UUID=old-root / ext4 defaults 0 1\n"
                "  UUID=old-efi\t/boot/efi vfat defaults 0 2\n"
                "tmpfs /tmp tmpfs defaults,nosuid 0 0\n"
            )
            subprocess.run(["bash", "-eu", "-c", 'source "$1"; update_image_fstab "$MNT"', "test", str(LIBRARY)], check=True, env={
                "PATH": os.environ["PATH"], "MNT": directory,
                "OLD_ROOT_UUID": "old-root", "ROOT_UUID": "new-root",
                "OLD_EFI_UUID": "old-efi", "EFI_UUID": "new-efi",
            })
            self.assertEqual(fstab.read_text(),
                "UUID=new-root / ext4 defaults 0 1\n"
                "UUID=new-efi /boot/efi vfat defaults 0 2\n"
                "tmpfs /tmp tmpfs defaults,nosuid 0 0\n"
            )
