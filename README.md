# OpenAstro for the Orange Pi 6 Plus

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

An Orange Pi 6 Plus port of [open-astro/openastro-orangepi4pro](https://github.com/open-astro/openastro-orangepi4pro),
modified 2026-10-23. Armbian **Debian 13 (Trixie), minimal CLI**, with
AlpacaBridge preinstalled, a NetworkManager WiFi hotspot, Ethernet DHCP,
SSH, persistent logs, and ZWO USB HID permissions.

**Status: native build, branded SD boot/artwork, Ethernet-backed hotspot client checks, and physical USB-to-NVMe installation/boot passed; equipment and USB-to-SD installation remain untested.**
No OpenAstro image release yet. Changes stay
uncommitted and unpushed until an image builds and passes the hardware checks
below. Upstream Git history and the GPLv2 license are preserved locally.

| Hardware | Target |
|----------|--------|
| Board | Orange Pi 6 Plus, CIX CD8180/CD8160 (Sky1) |
| Boot | Existing board UEFI firmware, GRUB, microSD image |
| Base image inspected | Armbian 26.8.3 Trixie, `6.18.45-current-arm64` |
| Initial WiFi/BT | Intel AX210 M.2 card; `iwlwifi` / `iwlmvm`, USB Bluetooth |
| Other WiFi adapters | Discovered automatically; require Linux driver, firmware, and AP support |

The [Armbian 6 Plus download](https://armbian.com/boards/orangepi6-plus)
currently redirects to the generic **UEFI ARM64** image, not an
`orangepi6plus`-named board image. Its GPT has a FAT EFI partition first and
an ext4 ARM64 root partition second. The builder detects these, grows only
the last/root partition, fixes the backup GPT, and mounts the EFI partition
at the image's configured location. It does **not** flash or update board firmware.
Each build gets fresh filesystem UUIDs and GPT identifiers, with fstab,
initramfs, the removable EFI loader, and GRUB updated so an attached base-image disk cannot be mistaken
for the new image. Two flashed copies of the same built image still share
those identifiers; do not attach both copies to the same board.

## Build on the Orange Pi 6 Plus

Use an already-running **aarch64 Linux** system on the board (or another
ARM64 machine). Internet and root access are needed for the chroot's package
installation. Keep at least **12 GiB free** for staging/output, plus the
downloaded input. Prefer NVMe for build workspace; never overwrite the
board's running boot media.

While this work is uncommitted, copy the local worktree to the board rather
than cloning the intentionally empty GitHub repository:

```bash
# On your workstation; replace USER and BOARD with your SSH login/host.
rsync -av --exclude=.git --exclude=.idea --exclude=images --exclude=__pycache__ \
    ./ USER@BOARD:~/openastro-orangepi6plus/
```

Then on the board, inside `~/openastro-orangepi6plus`:

```bash
sudo apt update
sudo apt install parted e2fsprogs dosfstools util-linux fdisk udev xz-utils python3 curl
mkdir -p images

# Only use a trusted Armbian ARM64 UEFI Debian Trixie minimal image.
curl -fL --retry 3 -o images/armbian-orangepi6plus.img.xz \
    https://dl.armbian.com/orangepi6-plus/Trixie_current_minimal
curl -fL --retry 3 -o images/armbian-orangepi6plus.img.xz.sha \
    https://dl.armbian.com/orangepi6-plus/Trixie_current_minimal.sha
awk '{print $1 "  images/armbian-orangepi6plus.img.xz"}' \
    images/armbian-orangepi6plus.img.xz.sha | sha256sum -c -

python3 -m unittest discover -s tests -v
bash tests/test-wifi.sh
sudo build/build-openastro-image.sh images/armbian-orangepi6plus.img.xz
```

Output: `images/openastro-orangepi6plus.img.xz` and `.sha256`.
The image is a readable distribution artifact: it contains your configured
hotspot credentials, so do not share a personalized image unintentionally.
The input image is never modified. An existing output is refused rather than
overwritten. Failed builds retain their staging directory for diagnosis;
cleanup does not lazily unmount or delete through busy mounts.

The download URL tracks Armbian's current release. The inspected source was
`Armbian_26.8.3_Uefi-arm64_trixie_current_6.18.45_minimal.img.xz`, SHA256
`c8a2c2f3e10374de0b89870658c80e1b82072ffc24af72ded35ef66090b19e28`.
Recheck layout, kernel support, and firmware requirements when it changes.

### Build-time settings

Existing setup overrides are inherited by the chroot; pass them **after**
`sudo` so it does not discard them:

```bash
# Replace CC with your actual two-letter country code.
sudo AP_COUNTRY=CC OPENASTRO_PASS='a-unique-login-password' \
    AP_PASSPHRASE='a-unique-hotspot-password' \
    build/build-openastro-image.sh images/armbian-orangepi6plus.img.xz
```

Other overrides: `AP_SSID` (1–27 simple ASCII characters; 5 bytes reserved
for the suffix), `AP_IP`, `AP_BAND`, `AP_CHANNEL`, `AP_INTERFACE` (optional
parent WiFi interface when multiple adapters exist), `OPENASTRO_HOSTNAME`,
`OPENASTRO_USER`, `INSTALL_ALPACABRIDGE=no`, and `TMPDIR` (staging location).
`KERNEL_DEBS=/path/to/debs` optionally installs matching ARM64 kernel
image/DTB/headers packages; a DTB package is not required on UEFI systems.

[`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) can also be run
on a booted Armbian Trixie ARM64 board with its companion
[`openastro-ap-iface.sh`](openastro/openastro-ap-iface.sh) and the `assets/`
directory alongside it.
**Re-running resets the login password and hotspot profile and replaces
netplan YAML files.** Do not run it over your only network connection without
console/recovery access. Reboot afterwards.

## Flash and boot

For installing from a USB thumb drive onto another SD/NVMe disk, see the
separate [offline USB installer](installer/README.md). It is experimental
and requires explicit erase confirmation; it is not part of the normal boot.

Flash the built image to a **separate microSD card** (16 GB+ recommended)
with Raspberry Pi Imager or balenaEtcher. Flashing erases the selected device;
do not select the running system's disk. Insert the card and select its
UEFI boot entry if another bootable drive takes precedence.

First verify that the **unmodified Armbian base image boots on your board**.
This customization cannot repair incompatible UEFI firmware or missing
kernel hardware support. Consult the board/Armbian firmware guidance; do
not apply the 4 Pro's Allwinner bootloader instructions.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` (`openastro.local` via mDNS) |
| Login | `astro` / `astro`; change immediately with `passwd` |
| Hotspot | `OpenAstro-XXXX`, 2.4 GHz channel 6, password `12345678` |
| Hotspot address | `172.24.1.1`, with DHCP/DNS/NAT for clients |
| Ethernet | Both ports managed by NetworkManager, DHCP |
| Regulatory country | `00` (world domain) until you set your actual country |
| AlpacaBridge | `http://openastro.local:6800` or `http://172.24.1.1:6800` |

The hotspot suffix is the last four hex digits of the first selected
adapter's MAC, written on the first boot that finds a suitable radio.
SSH host keys and the machine ID are generated per device. Default
credentials are for initial setup, **not safe for an untrusted network**.

New builds use the OpenAstro logo as GRUB's background and label its menu
OpenAstro, keeping the existing three-second automatic boot and visible
kernel diagnostics. The [artwork](openastro/assets/README.md) does not replace
the board's UEFI/CIX startup image or the kernel logo; those are outside
this filesystem customization. No Plymouth splash stack is added.

**Latest normal test image:** `images/openastro-orangepi6plus-branded.img.xz`.
Its native build and offline inspection confirm the OpenAstro GRUB background,
removed factory root-autologin overrides, 48-bit VA, and the ZWO HID fix.
Physical SD boot, root expansion, password SSH, and basic service/hotspot
checks passed. The user confirmed visual boot artwork, hotspot client access
to AlpacaBridge, and internet through Ethernet. Equipment testing remains
pending. The older unbranded
artifact booted but retained root autologin; do not use that as a release.

## WiFi: AX210 and other adapters

Intel firmware is explicitly installed, along with Debian firmware packages
for common Atheros, Broadcom, MediaTek, and Realtek adapters. That does not
add missing kernel drivers or guarantee that every adapter supports AP mode.
No proprietary/out-of-tree WiFi driver is bundled by this port.

At boot the helper finds an AP-capable adapter without assuming `phy0` or
`wlan0`, creates `ap0`, assigns a distinct MAC, binds the hotspot to it, and
sets the per-device SSID before NetworkManager starts. If the driver refuses
a virtual AP interface, it uses the physical interface instead (AP **or**
client). With no suitable radio, Ethernet and AlpacaBridge still start;
the journal reports the missing hotspot. Attach an adapter before boot;
reboot after replacing it. An optional parent-interface selection is stored
in `/etc/default/openastro-ap`.

**AX210 limits** ([Linux wireless documentation](https://wireless.docs.kernel.org/en/latest/en/users/drivers/iwlwifi.html)):

- Hotspot/AP mode is **2.4 GHz only**. A regulatory country does **not**
  unlock a 5/6 GHz Intel hotspot. Client mode can use the other bands where allowed.
- The kernel driver advertises AP+client concurrency on **one channel**.
  A hotspot on 2.4 GHz channel 6 cannot simultaneously serve a 5 GHz client
  uplink on the same AX210. Even same-channel concurrency needs testing.
- Use Ethernet, or a second compatible WiFi radio, to keep the hotspot
  available independently of the client uplink. Full 4 Pro mixed-band
  concurrency is not promised for this card.

For another adapter, 5 GHz AP operation also requires driver/firmware
support and a permitted channel/country. The shared-mode hotspot forwards
through whichever working uplink NetworkManager has.

To connect a client-capable interface (subject to those limits):

```bash
nmcli device status
sudo nmcli device wifi connect 'YOUR_SSID' password 'YOUR_PASSWORD' ifname YOUR_CLIENT_INTERFACE
```

The AlpacaBridge WiFi UI is supplied by its apt package, not this repository;
verify its handling of the actual interface names during board validation.

## AlpacaBridge and ZWO

AlpacaBridge is installed from the signed OpenAstro apt repository, so the
image does not need internet at the observing site. Update it normally:

```bash
sudo apt update && sudo apt upgrade
```

The inspected stock kernel enables `CONFIG_HIDRAW=y` and
`CONFIG_USB_HIDDEV=y`. Linux stable 6.18.45 already includes the malformed
HID descriptor fix required by ZWO EAF/EFW, so the Allwinner 6.6 kernel config
is not reused. The portable config fragment and original backport are kept
in [`hardware/orangepi6plus-cix/kernel/`](hardware/orangepi6plus-cix/kernel/README.md)
as reference inputs, not reapplied to the already-fixed kernel.
ZWO access is granted to `plugdev`, including
the login user and AlpacaBridge service user, rather than world-writable HID
devices. Real EAF/EFW/camera and ASCOM ConformU tests are still required.

## Running ASan + UBSan tests

The supplied ARM64 kernel already has `CONFIG_ARM64_VA_BITS_48=y`,
`CONFIG_ARM64_VA_BITS=48`, and 4 KiB pages. No kernel rebuild is needed to
provide the 48-bit virtual address space requested by sanitizer tests.
This is separate from physical RAM size or `CONFIG_KASAN` (kernel sanitizing).

Development tools are deliberately not preinstalled in the appliance image.
On the board where you will build/run tests:

```bash
sudo apt update
sudo apt install build-essential
bash tests/test-sanitizers.sh
```

The smoke test compiles with `-fsanitize=address,undefined`, verifies clean
execution, then requires actual ASan and UBSan diagnostics from deliberate
errors. It also leaves leak detection enabled. `CC=clang` can select an
already-installed Clang toolchain instead. This checks the runtime, not the
AlpacaBridge test suite; configure that project's own sanitizer build separately.

Do not impose a small `ulimit -v` on sanitizer processes: shadow memory
reserves a large virtual range without requiring that much physical RAM.
Also, 39-bit VA is not universally incompatible with ASan: LLVM provides
a Linux/AArch64 39-bit mapping. A failure on another board needs its exact
compiler/runtime version and error output, not just the VA-bit count.

## Validation before committing or publishing an image

See [`hardware/orangepi6plus-cix/inventory.md`](hardware/orangepi6plus-cix/inventory.md)
for the hardware acceptance checklist. Useful diagnostics:

```bash
uname -a
lsblk -f
nmcli device status
iw dev
iw list
iw reg get
systemctl status openastro-ap-iface NetworkManager ssh alpacabridge
journalctl -b -u openastro-ap-iface -u NetworkManager -u alpacabridge
```

Local checks, without root or ARM64 hardware (the keyfile test uses `nmcli`
when available):

```bash
bash -n build/build-openastro-image.sh openastro/*.sh tests/test-wifi.sh
python3 -m unittest discover -s tests -v
bash tests/test-wifi.sh
```

These check parsing and WiFi setup logic, not actual boot, radios, NAT, or USB devices.

## License and provenance

Derived from [open-astro/openastro-orangepi4pro](https://github.com/open-astro/openastro-orangepi4pro)
at `37499f01e6c756fcea2d2c0823a78aa9bb435db5`. Modified files identify the
Orange Pi 6 Plus port and date. See [LICENSE.md](LICENSE.md) (GPLv2).
Armbian, AlpacaBridge, firmware, and other installed packages retain their
own licenses; preserve corresponding-source/license obligations when distributing images.
