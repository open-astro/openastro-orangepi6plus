"""Run the setup's real preflight, stopping before package/system changes."""

import os
from pathlib import Path
import subprocess
import shutil
import unittest

SETUP = Path(__file__).resolve().parents[1] / "openastro/openastro-setup.sh"
PREFLIGHT = SETUP.read_text().split('log "Installing packages..."')[0]
# Only fake platform checks; no package, network, or filesystem mutation runs.
PLATFORM = '''
id() { echo 0; }
dpkg() { echo arm64; }
grep() {
    if [ "${*: -1}" = /etc/os-release ]; then return 0; fi
    command grep "$@"
}
'''


class SetupConfigTests(unittest.TestCase):
    def run_preflight(self, **settings):
        env = {"PATH": os.environ["PATH"], **settings}
        return subprocess.run(
            ["bash", "-c", PLATFORM + PREFLIGHT + '\necho preflight-ok', str(SETUP)],
            env=env, text=True, capture_output=True,
        )

    def test_defaults(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("preflight-ok", result.stdout)

    def test_valid_overrides(self):
        result = self.run_preflight(
            AP_SSID="My Astro-6", AP_COUNTRY="GB", AP_INTERFACE="wlp1s0",
            AP_IP="192.168.50.1", OPENASTRO_PASS="a-unique-password",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("nmcli"), "nmcli not installed")
    def test_generated_hotspot_keyfile(self):
        profile = SETUP.read_text().split(
            'cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF\n'
        )[1].split('\nEOF')[0]
        generated = subprocess.run(
            ["bash", "-c", PLATFORM + PREFLIGHT +
             '\nAP_UUID=3d28d55d-c239-4f85-a622-9beb15465728\ncat <<EOF\n' + profile + '\nEOF', str(SETUP)],
            env={"PATH": os.environ["PATH"]}, text=True, capture_output=True, check=True,
        )
        parsed = subprocess.run(
            ["nmcli", "--offline", "connection", "modify", "connection.autoconnect", "yes"],
            input=generated.stdout, text=True, capture_output=True, check=True,
        ).stdout
        for setting in ("address1=172.24.1.1/24", "ssid=OpenAstro", "mode=ap", "psk=12345678", "interface-name=ap0"):
            self.assertIn(setting, parsed)

    def test_reject_unsafe_or_invalid_settings(self):
        for key, value in (
            ("AP_IP", "172.24.1.1\npsk=injected"),
            ("AP_IP", "172.24.1.1."), ("AP_IP", "172.24.1.256"),
            ("AP_IP", "172.24.1.0"), ("AP_IP", "172.24.1.255"),
            ("AP_SSID", "a" * 28), ("AP_SSID", "bad\nssid"),
            ("AP_PASSPHRASE", "short"), ("AP_PASSPHRASE", "trailing "),
            ("AP_COUNTRY", "not-a-country"), ("AP_CHANNEL", "6\nssid=bad"),
            ("AP_INTERFACE", "bad/interface"), ("OPENASTRO_HOSTNAME", "-bad"),
            ("OPENASTRO_USER", "bad:user"), ("OPENASTRO_PASS", "bad:password"),
        ):
            with self.subTest(setting=key, value=value):
                result = self.run_preflight(**{key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("preflight-ok", result.stdout)


if __name__ == "__main__":
    unittest.main()
