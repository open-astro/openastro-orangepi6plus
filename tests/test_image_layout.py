"""Small rootless checks for the image builder's partition selection."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "image_layout", Path(__file__).resolve().parents[1] / "build/image-layout.py"
)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


class ImageLayoutTests(unittest.TestCase):
    def setUp(self):
        self.table = {
            "label": "gpt",
            "device": "/dev/loop12",
            "partitions": [
                {"node": "/dev/loop12p1", "type": layout.EFI.upper(), "start": 8192, "size": 532480},
                {"node": "/dev/loop12p2", "type": layout.ARM64_ROOT, "start": 540672, "size": 9508864},
            ],
        }

    def test_real_armbian_layout(self):
        self.assertEqual(layout.image_layout(self.table), ("/dev/loop12p2", "2", "/dev/loop12p1"))

    def test_generic_linux_guid_and_reordered_partition_numbers(self):
        self.table["partitions"][1].update(type=layout.LINUX, node="/dev/loop12p3")
        self.assertEqual(layout.image_layout(self.table)[1], "3")

    def test_reject_mbr(self):
        self.table["label"] = "dos"
        with self.assertRaisesRegex(ValueError, "GPT"):
            layout.image_layout(self.table)

    def test_reject_ambiguous_root(self):
        self.table["partitions"].append(copy.deepcopy(self.table["partitions"][1]))
        with self.assertRaisesRegex(ValueError, "exactly one"):
            layout.image_layout(self.table)

    def test_reject_missing_efi(self):
        self.table["partitions"].pop(0)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            layout.image_layout(self.table)

    def test_reject_root_not_last(self):
        self.table["partitions"][0]["start"] = 11000000
        with self.assertRaisesRegex(ValueError, "last"):
            layout.image_layout(self.table)

    def test_reject_unexpected_device(self):
        self.table["partitions"][1]["node"] = "/dev/nvme0n1p2"
        with self.assertRaisesRegex(ValueError, "selected device"):
            layout.image_layout(self.table)

    def test_physical_sd_and_nvme_names(self):
        for device in ("/dev/sda", "/dev/mmcblk0", "/dev/nvme0n1"):
            with self.subTest(device=device):
                prefix = device + ("p" if device[-1].isdigit() else "")
                self.table["device"] = device
                for i, part in enumerate(self.table["partitions"], 1):
                    part["node"] = f"{prefix}{i}"
                self.assertEqual(layout.image_layout(self.table), (f"{prefix}2", "2", f"{prefix}1"))


if __name__ == "__main__":
    unittest.main()
