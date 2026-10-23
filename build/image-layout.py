#!/usr/bin/env python3
"""Read sfdisk --json and select an unambiguous UEFI/ext4 image layout.

Orange Pi 6 Plus port, 2026-10-23; derived project licensed under GPLv2.
"""

import json
import sys

EFI = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX = "0fc63daf-8483-4772-8e79-3d69d8477de4"
ARM64_ROOT = "b921b045-1df0-41c3-af44-4c6f280d3fae"


def image_layout(table):
    if table["label"] != "gpt":
        raise ValueError("Expected a GPT/UEFI Armbian image")
    parts = table["partitions"]
    roots = [p for p in parts if p["type"].lower() in (LINUX, ARM64_ROOT)]
    efis = [p for p in parts if p["type"].lower() == EFI]
    if len(roots) != 1 or len(efis) != 1:
        raise ValueError("Expected exactly one Linux root and one EFI partition")
    root, efi = roots[0], efis[0]
    if root != max(parts, key=lambda p: p["start"] + p["size"]):
        raise ValueError("Root partition must be last to grow it safely")
    device = table["device"]
    prefix = device + ("p" if device[-1:].isdigit() else "")
    for part in (root, efi):
        number = part["node"].removeprefix(prefix)
        if not number.isdecimal() or int(number) < 1:
            raise ValueError("Expected partitions belonging to the selected device")
    return root["node"], root["node"][len(prefix):], efi["node"]


if __name__ == "__main__":
    try:
        print(*image_layout(json.load(sys.stdin)["partitiontable"]))
    except (KeyError, TypeError, ValueError) as error:
        sys.exit(f"Unsupported image layout: {error}")
