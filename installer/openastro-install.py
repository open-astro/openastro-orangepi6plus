#!/usr/bin/env python3
"""Offline, explicitly destructive OpenAstro disk installer (GPLv2)."""

import fcntl
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

PAYLOAD = Path("/opt/openastro-installer/payload.img.xz")
MANIFEST = PAYLOAD.with_name("manifest.json")
BACKEND = "/usr/lib/openastro-installer/finish-install.sh"
DEVICES = re.compile(r"/dev/(?:sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)\Z")
CHUNK = 4 * 1024 * 1024
REQUIRED_TOOLS = (
    "lsblk", "findmnt", "blockdev", "sfdisk", "blkid", "parted", "partprobe",
    "udevadm", "e2fsck", "resize2fs", "tune2fs", "fatlabel", "mount", "umount",
    "mountpoint", "chroot", "sync", "python3", "grub-install", "update-initramfs", "update-grub",
)


def preflight_tools():
    missing = [name for name in REQUIRED_TOOLS if not shutil.which(name)]
    if missing or not os.path.isfile(BACKEND) or not os.access(BACKEND, os.X_OK):
        raise RuntimeError(f"Installer tools are incomplete ({', '.join(missing) or BACKEND}); no disk was modified.")


def walk(node):
    yield node
    for child in node.get("children") or []:
        yield from walk(child)


def eligible_disks(inventory, root_id, required):
    disks = inventory["blockdevices"]
    if not any(n.get("maj:min") == root_id and "/" in (n.get("mountpoints") or [])
               for disk in disks for n in walk(disk)):
        raise RuntimeError("Cannot identify the running root disk; refusing installation.")
    result = []
    for disk in disks:
        if disk.get("type") != "disk" or not DEVICES.fullmatch(disk.get("name", "")):
            continue
        # shortcut: payload GPT uses 512-byte sectors; re-layout the image to support 4Kn.
        if disk.get("ro") or disk.get("log-sec") != 512 or disk.get("size", 0) < required:
            continue
        if not disk.get("diskseq"):
            continue
        if any(n.get("ro") or n.get("holders") or n.get("type") not in ("disk", "part")
               or any(n.get("mountpoints") or []) for n in walk(disk)):
            continue
        result.append(disk)
    return result


def snapshot(required):
    data = json.loads(subprocess.check_output([
        "lsblk", "--json", "--bytes", "--paths", "--output",
        "NAME,TYPE,SIZE,RO,MODEL,SERIAL,MAJ:MIN,LOG-SEC,MOUNTPOINTS",
    ], text=True))
    root_id = subprocess.check_output([
        "findmnt", "--noheadings", "--output", "MAJ:MIN", "--target", "/",
    ], text=True).strip()
    for disk in data["blockdevices"]:
        for node in walk(disk):
            sysfs = Path("/sys/class/block") / Path(node["name"]).name
            # Unknown sysfs state is unsafe, not evidence that a disk is unused.
            try:
                node["holders"] = any((sysfs / "holders").iterdir())
            except OSError:
                node["holders"] = True
        try:
            disk["diskseq"] = int((Path("/sys/class/block") / Path(disk["name"]).name / "diskseq").read_text())
        except (OSError, ValueError):
            disk["diskseq"] = None
    return eligible_disks(data, root_id, required)


def identity(disk):
    return tuple(disk.get(k) for k in ("name", "maj:min", "diskseq", "size", "serial"))


def load_manifest(path):
    if path.stat().st_size > 4096:
        raise ValueError("Invalid installer manifest size.")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("format") != 1 or type(data.get("image_bytes")) is not int:
        raise ValueError("Unsupported installer manifest.")
    if data["image_bytes"] <= 0 or data["image_bytes"] % 512:
        raise ValueError("Invalid payload image size.")
    for key in ("compressed_sha256", "image_sha256"):
        if not isinstance(data.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", data[key]):
            raise ValueError("Invalid payload digest.")
    return data


def verify_payload(stream, manifest):
    stream.seek(0)
    if hashlib.file_digest(stream, "sha256").hexdigest() != manifest["compressed_sha256"]:
        raise ValueError("Payload checksum failed; no target has been modified.")
    stream.seek(0)


def write_all(fd, data):
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise OSError("Short write to installation target.")
        view = view[count:]


def write_and_verify(stream, fd, capacity, manifest):
    """Caller owns the exclusively opened and revalidated target descriptor."""
    expected = manifest["image_bytes"]
    if capacity < expected:
        raise ValueError("Target is too small.")
    # Invalidate old leading/trailing partition and RAID signatures, not a secure erase.
    zeros = bytes(min(1024 * 1024, capacity))
    os.lseek(fd, 0, os.SEEK_SET)
    write_all(fd, zeros)
    os.lseek(fd, capacity - len(zeros), os.SEEK_SET)
    write_all(fd, zeros)
    os.lseek(fd, 0, os.SEEK_SET)
    total = 0
    digest = hashlib.sha256()
    with lzma.LZMAFile(stream) as image:
        while data := image.read(CHUNK):
            total += len(data)
            if total > expected:
                raise ValueError("Payload exceeds its declared image size.")
            write_all(fd, data)
            digest.update(data)
    if total != expected or digest.hexdigest() != manifest["image_sha256"]:
        raise ValueError("Uncompressed payload verification failed; target is incomplete.")
    print("Payload written; flushing and verifying target read-back...", flush=True)
    os.fsync(fd)
    if stat.S_ISBLK(os.fstat(fd).st_mode):
        # Linux BLKFLSBUF: verify device reads, not the kernel's cached writes.
        fcntl.ioctl(fd, 0x1261)
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    remaining = expected
    while remaining:
        data = os.read(fd, min(CHUNK, remaining))
        if not data:
            raise OSError("Short read during target verification.")
        digest.update(data)
        remaining -= len(data)
    if digest.hexdigest() != manifest["image_sha256"]:
        raise ValueError("Target read-back checksum failed; do not boot this target.")


def install(disk, stream, manifest):
    print("Checking bundled payload before touching the target...", flush=True)
    verify_payload(stream, manifest)
    current = next((d for d in snapshot(manifest["image_bytes"]) if identity(d) == identity(disk)), None)
    if current is None:
        raise RuntimeError("Target changed or is now in use; nothing was written.")
    fd = os.open(disk["name"], os.O_RDWR | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        device_id = f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}"
        if not stat.S_ISBLK(info.st_mode) or device_id != disk["maj:min"]:
            raise RuntimeError("Selected device identity changed.")
        seq = int((Path("/sys/class/block") / Path(disk["name"]).name / "diskseq").read_text())
        capacity = os.lseek(fd, 0, os.SEEK_END)
        if seq != disk["diskseq"] or capacity != disk["size"]:
            raise RuntimeError("Selected device changed before installation.")
        print("Writing and verifying the payload. Do not disconnect either drive.", flush=True)
        write_and_verify(stream, fd, capacity, manifest)
    finally:
        os.close(fd)
    print("Payload verified. Configuring unique identifiers and EFI boot...", flush=True)
    subprocess.run([BACKEND, disk["name"], str(disk["diskseq"]), str(disk["size"])], check=True)


def main():
    if os.geteuid() != 0 or os.uname().machine != "aarch64" or not Path("/sys/firmware/efi").is_dir():
        raise RuntimeError("Run this installer as root on an ARM64 UEFI system.")
    preflight_tools()
    with open("/run/openastro-installer.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = load_manifest(MANIFEST)
        disks = snapshot(manifest["image_bytes"])
        print("\nOpenAstro Orange Pi 6 Plus - offline installer\n")
        print("Installation ERASES the entire selected disk. It is not a secure erase.")
        print("Boot media, mounted/in-use devices, read-only and 4Kn disks are excluded.\n")
        if not disks:
            print("No eligible targets. Attach an unused SD/NVMe disk and reboot the installer.")
            return
        for i, disk in enumerate(disks, 1):
            model = ascii((disk.get("model") or "").strip())
            serial = ascii((disk.get("serial") or "").strip())
            print(f"{i}: {disk['name']}  {disk['size'] / 2**30:.1f} GiB  model={model} serial={serial}")
        choice = input("\nTarget number, or q to cancel: ").strip()
        if choice.lower() == "q":
            print("Cancelled; no disk changed. Reboot the installer to try again.")
            return
        if not choice.isdecimal() or not 1 <= int(choice) <= len(disks):
            raise ValueError("Invalid selection; no target has been modified.")
        disk = disks[int(choice) - 1]
        phrase = f"ERASE {disk['name']}"
        if input(f"Type exactly {phrase!r} to confirm: ") != phrase:
            print("Cancelled; no disk changed. Reboot the installer to try again.")
            return
        with PAYLOAD.open("rb") as stream:
            install(disk, stream, manifest)
        print("\nInstallation finished. Power off, remove the installer USB, then boot the installed disk.")
        if input("Type POWER OFF to shut down now; otherwise press Enter: ") == "POWER OFF":
            subprocess.run(["systemctl", "poweroff"], check=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, lzma.LZMAError) as error:
        print(f"\nInstallation did not finish: {error}\nIf writing started, the selected target may be incomplete.", file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled. If writing started, the selected target may be incomplete.", file=sys.stderr)
        sys.exit(130)
