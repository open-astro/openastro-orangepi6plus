"""Rootless safety/integrity tests; never open or write a real block device."""

import hashlib
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, REPO / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


installer = load("installer", "installer/openastro-install.py")
manifest_builder = load("installer_manifest", "build/installer-manifest.py")


def disk(name, number, **overrides):
    return {"name": name, "type": "disk", "size": 16 * 2**30, "ro": False,
            "log-sec": 512, "maj:min": f"8:{number}", "diskseq": number + 1,
            "serial": f"serial-{number}", "mountpoints": [None], "holders": False,
            **overrides}


class TargetSelectionTests(unittest.TestCase):
    def setUp(self):
        self.boot = disk("/dev/sda", 0, children=[{
            "name": "/dev/sda2", "type": "part", "maj:min": "8:2", "mountpoints": ["/"],
        }])
        self.target = disk("/dev/nvme0n1", 16)

    def candidates(self, *others, root="8:2"):
        return installer.eligible_disks({"blockdevices": [self.boot, *others]}, root, 8 * 2**30)

    def test_boot_disk_excluded_sd_nvme_allowed(self):
        sd = disk("/dev/mmcblk0", 32)
        self.assertEqual(self.candidates(self.target, sd), [self.target, sd])

    def test_unknown_root_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "root disk"):
            self.candidates(self.target, root="0:42")

    def test_reject_unsafe_targets(self):
        variants = [
            {"ro": True}, {"log-sec": 4096}, {"size": 1024}, {"diskseq": None},
            {"holders": True}, {"name": "/dev/loop0"}, {"name": "/dev/mtdblock0"},
            {"name": "/dev/mmcblk0boot0"}, {"name": "/dev/disk/by-id/alias"},
            {"mountpoints": ["/boot/efi"]}, {"mountpoints": ["[SWAP]"]},
            {"children": [{"type": "part", "mountpoints": ["/mnt/data"]}]},
            {"children": [{"type": "crypt", "mountpoints": [None]}]},
            {"children": [{"type": "part", "holders": True}]},
        ]
        for changes in variants:
            with self.subTest(changes=changes):
                candidate = self.target | changes
                self.assertEqual(self.candidates(candidate), [])

    def test_bad_payload_never_opens_target(self):
        meta = {"compressed_sha256": "0" * 64}
        with mock.patch.object(installer.os, "open") as opened:
            with self.assertRaisesRegex(ValueError, "checksum"):
                installer.install(self.target, io.BytesIO(b"corrupt"), meta)
            opened.assert_not_called()

    def test_changed_or_now_mounted_target_never_opens(self):
        payload = b"verified"
        meta = {"compressed_sha256": hashlib.sha256(payload).hexdigest(), "image_bytes": 512}
        changed = self.target | {"diskseq": 999}
        for available in ([], [changed]):
            with self.subTest(available=available), mock.patch.object(installer, "snapshot", return_value=available), mock.patch.object(installer.os, "open") as opened:
                with self.assertRaisesRegex(RuntimeError, "changed"):
                    installer.install(self.target, io.BytesIO(payload), meta)
                opened.assert_not_called()

    def test_exclusive_open_failure_does_not_run_backend(self):
        data = b"verified"
        meta = {"compressed_sha256": hashlib.sha256(data).hexdigest(), "image_bytes": 512}
        with mock.patch.object(installer, "snapshot", return_value=[self.target]), mock.patch.object(installer.os, "open", side_effect=OSError("busy")) as opened, mock.patch.object(installer.subprocess, "run") as backend:
            with self.assertRaises(OSError):
                installer.install(self.target, io.BytesIO(data), meta)
            self.assertTrue(opened.call_args.args[1] & os.O_EXCL)
            self.assertTrue(opened.call_args.args[1] & os.O_NOFOLLOW)
            backend.assert_not_called()

    def test_menu_cancel_and_bad_confirmation_never_install(self):
        for answers in (["q"], ["1", ""], ["1", "ERASE /dev/sda"]):
            with self.subTest(answers=answers), \
                    mock.patch.object(installer.os, "geteuid", return_value=0), \
                    mock.patch.object(installer.os, "uname", return_value=mock.Mock(machine="aarch64")), \
                    mock.patch.object(installer.Path, "is_dir", return_value=True), \
                    mock.patch.object(installer, "open", mock.mock_open(), create=True), \
                    mock.patch.object(installer, "preflight_tools"), \
                    mock.patch.object(installer.fcntl, "flock"), \
                    mock.patch.object(installer, "load_manifest", return_value={"image_bytes": 512}), \
                    mock.patch.object(installer, "snapshot", return_value=[self.target]), \
                    mock.patch("builtins.input", side_effect=answers), \
                    mock.patch("sys.stdout", new_callable=io.StringIO), \
                    mock.patch.object(installer, "install") as install:
                installer.main()
                install.assert_not_called()

    def test_missing_tools_or_backend_fail_before_any_disk_open(self):
        for exists in (True, False):
            with self.subTest(backend_exists=exists), mock.patch.object(installer.shutil, "which", return_value="/usr/bin/tool" if not exists else None), mock.patch.object(installer.os.path, "isfile", return_value=exists), mock.patch.object(installer.os, "access", return_value=exists), mock.patch.object(installer.os, "open") as opened:
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    installer.preflight_tools()
                opened.assert_not_called()


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "payload.img.xz"
        self.raw = (b"OpenAstro image verification\n" * 512).ljust(16384, b"\0")
        self.path.write_bytes(lzma.compress(self.raw))
        self.meta = manifest_builder.manifest(self.path)

    def test_manifest_and_compressed_verification(self):
        manifest = self.path.with_name("manifest.json")
        manifest.write_text(json.dumps(self.meta))
        self.assertEqual(installer.load_manifest(manifest), self.meta)
        with self.path.open("rb") as stream:
            installer.verify_payload(stream, self.meta)
            self.assertEqual(stream.tell(), 0)

    def test_staging_cannot_modify_live_root(self):
        result = subprocess.run(
            ["bash", str(REPO / "build/stage-installer.sh"), "/", str(self.path)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("never the running system", result.stderr)

    def test_reject_malformed_manifest(self):
        path = self.path.with_name("manifest.json")
        cases = [[], {}, self.meta | {"image_bytes": -512}, self.meta | {"image_bytes": True},
                 self.meta | {"image_bytes": 513}, self.meta | {"image_sha256": []},
                 self.meta | {"compressed_sha256": "not a digest"}]
        for value in cases:
            with self.subTest(value=value):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    installer.load_manifest(path)

    def test_write_and_readback_on_regular_file(self):
        target = self.path.with_name("target.img")
        capacity = 3 * 1024 * 1024
        target.write_bytes(b"x" * capacity)
        with target.open("r+b") as output, self.path.open("rb") as stream, mock.patch("sys.stdout", new_callable=io.StringIO):
            installer.write_and_verify(stream, output.fileno(), capacity, self.meta)
            output.seek(0)
            self.assertEqual(output.read(len(self.raw)), self.raw)
            output.seek(-1024 * 1024, os.SEEK_END)
            self.assertEqual(output.read(), bytes(1024 * 1024))
        self.assertEqual(target.stat().st_size, capacity)

    def test_too_small_target_untouched(self):
        target = self.path.with_name("small.img")
        target.write_bytes(b"preserve this")
        with target.open("r+b") as output, self.path.open("rb") as stream:
            with self.assertRaisesRegex(ValueError, "small"):
                installer.write_and_verify(stream, output.fileno(), 13, self.meta)
        self.assertEqual(target.read_bytes(), b"preserve this")

    def test_bad_raw_digest_never_runs_backend(self):
        target = self.path.with_name("target.img")
        target.write_bytes(bytes(3 * 1024 * 1024))
        meta = self.meta | {"image_sha256": "0" * 64}
        with target.open("r+b") as output, self.path.open("rb") as stream:
            with self.assertRaisesRegex(ValueError, "verification failed"):
                installer.write_and_verify(stream, output.fileno(), target.stat().st_size, meta)

    def test_declared_size_cannot_be_overrun(self):
        target = self.path.with_name("target.img")
        target.write_bytes(bytes(3 * 1024 * 1024))
        meta = self.meta | {"image_bytes": 512}
        with target.open("r+b") as output, self.path.open("rb") as stream:
            with self.assertRaisesRegex(ValueError, "exceeds"):
                installer.write_and_verify(stream, output.fileno(), target.stat().st_size, meta)

    def test_readback_error_is_not_reported_as_success(self):
        target = self.path.with_name("target.img")
        target.write_bytes(bytes(3 * 1024 * 1024))
        with target.open("r+b") as output, self.path.open("rb") as stream, mock.patch.object(installer.os, "read", return_value=b"!" * len(self.raw)), mock.patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaisesRegex(ValueError, "read-back checksum"):
                installer.write_and_verify(stream, output.fileno(), target.stat().st_size, self.meta)

    def test_short_writes_are_retried_and_zero_write_fails(self):
        with mock.patch.object(installer.os, "write", side_effect=[2, 2]) as write:
            installer.write_all(99, b"data")
            self.assertEqual(bytes(write.call_args_list[1].args[1]), b"ta")
        with mock.patch.object(installer.os, "write", return_value=0):
            with self.assertRaises(OSError):
                installer.write_all(99, b"data")
