#!/usr/bin/env python3
"""Record compressed and raw integrity checks for the offline payload."""

import hashlib
import json
import lzma
from pathlib import Path
import sys


def manifest(path):
    digest = hashlib.sha256()
    size = 0
    with lzma.open(path, "rb") as image:
        while data := image.read(4 * 1024 * 1024):
            digest.update(data)
            size += len(data)
    with path.open("rb") as compressed:
        compressed_digest = hashlib.file_digest(compressed, "sha256").hexdigest()
    if size <= 0 or size % 512:
        raise ValueError("Payload must be a sector-aligned disk image.")
    return {"format": 1, "image_bytes": size, "image_sha256": digest.hexdigest(),
            "compressed_sha256": compressed_digest}


if __name__ == "__main__":
    print(json.dumps(manifest(Path(sys.argv[1])), indent=2))
