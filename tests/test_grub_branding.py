"""Check the shipped bitmap and the real GRUB settings without root."""

from pathlib import Path
import struct
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]


class GrubBrandingTests(unittest.TestCase):
    def test_background_is_standard_rgb_png(self):
        data = (REPO / "openastro/assets/grub-background.png").read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(data[12:16], b"IHDR")
        self.assertEqual(struct.unpack_from(">IIBB", data, 16), (1920, 1080, 8, 2))

    def test_grub_fragment_uses_openastro_asset_and_title(self):
        setup = (REPO / "openastro/openastro-setup.sh").read_text()
        fragment = setup.split(
            "cat > /etc/default/grub.d/99-openastro-branding.cfg <<'EOF'\n"
        )[1].split("\nEOF")[0]
        result = subprocess.check_output(
            ["bash", "-eu", "-c", fragment + '\nprintf "%s\\n" "$GRUB_DISTRIBUTOR" "$GRUB_BACKGROUND"'],
            text=True,
        )
        self.assertEqual(result.splitlines(), [
            "OpenAstro", "/usr/share/images/openastro/grub-background.png"
        ])
