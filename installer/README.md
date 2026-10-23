# Offline USB installer — Orange Pi 6 Plus

**Experimental: physical USB installation and NVMe boot passed on one board;
physical SD installation remains untested. Automated tests never write real disks.**

## Built test artifact

Available locally as `images/openastro-orangepi6plus-installer.img.xz`
(801,795,144 bytes compressed; raw `.img` is 9,441,378,304 bytes).
SHA256:
`12756d9529cd5554c29916fdc160481ab68ef62b5c265bde5118ff1952c1a278`.

Native build, 34 rootless checks, the ARM64 file-backed loop integration
test, GPT/FAT/ext4 inspection, enabled console service, service masks, and
embedded payload integrity passed. `images/verification-installer.json`
records the offline results. **The user completed physical USB installation
onto NVMe and booted it with the SD and installer USB removed.** Read-only
checks confirmed NVMe root/EFI, fresh filesystem IDs, full-drive root growth,
active SSH/hotspot/AlpacaBridge, and no installer service on the target.
Physical SD installation remains untested. No automatic disk install
occurs on boot; selection and the erase phrase are required.

This is a separate image, not a new first-boot mode in the normal appliance.
The USB carrier contains a compressed, normal OpenAstro image and its
compressed/raw SHA256 checksums. Installation does not copy the running
installer's files or configuration into the target.

## Build

First build and verify the normal OpenAstro `.img.xz` (including the HID
requirements, boot branding, and root-autologin fix). On an ARM64 build host:

```bash
sudo build/build-openastro-installer.sh \
    images/openastro-orangepi6plus-branded.img.xz \
    images/openastro-orangepi6plus-installer.img.xz
```

The normal image is input only and is never modified. The carrier reuses
the normal builder, adding the payload, Python console UI, standard filesystem
tools, and a tty1 installer service. Its hostname/menu identify it as
`openastro-installer` / OpenAstro Installer. Root shell auto-login remains
disabled; the privileged tty1 program only offers installation or cancellation.
AlpacaBridge, SSH, and automatic disk mounting are masked **on the carrier
only**. This first version is console-only; it does not expose default-password
SSH access to a disk-erasing environment. The installed payload has ordinary
login, SSH, and AlpacaBridge enabled.

Allow at least 12 GiB of build workspace plus input/output files. A **16 GB+
USB drive** is recommended for the installer image. The target must fit the
uncompressed payload; the menu checks its actual capacity.

## Use

1. Flash the installer `.img.xz` to a spare USB thumb drive with Imager's
   OS customization **disabled**. Flashing erases that USB drive.
2. Boot the Orange Pi 6 Plus from that USB with a keyboard/monitor connected.
3. Choose the SD/NVMe target by device, model, serial, and capacity.
4. Type the exact displayed `ERASE /dev/...` phrase. There is no default target
   or unattended `--yes` mode.
5. Wait for payload checks, writing, read-back verification, filesystem growth,
   unique UUID/GPT configuration, initramfs generation, and EFI installation.
6. Power off when offered, remove the installer USB, and boot the target.

If another bootable SD/NVMe drive is still present, remove that other boot
media or select the newly installed target in UEFI Boot Manager. The installer
does not rewrite the firmware's saved boot order.

**All files/partitions on the selected target are destroyed. This is not a
secure wipe:** data outside the image's writes may remain recoverable.
No SPI firmware or UEFI NVRAM boot entries are written.

## Safety boundaries

- Only whole SD-style, eMMC/SD, and NVMe device names are eligible; no partitions,
  loop devices, SPI/MTD, device-mapper, or firmware boot areas.
- The running root disk must be identifiable, or the installer fails closed.
  Boot/EFI disks and all mounted, swap, held, read-only, too-small, and 4Kn
  devices are excluded. First version supports **512-byte logical sectors**.
- The candidate is checked again after confirmation and payload verification.
  Its kernel disk sequence, major/minor, serial, and capacity must still match.
- The write uses an exclusive, non-symlink block-device descriptor; the device
  identity/capacity is checked before the first write.
- The compressed payload is checked before disk writes; the raw image is checked
  while writing and reread/hashed from the target after flushing block buffers.
- The shared UEFI helper updates only the selected target, uses read-only host
  sysfs, and installs an ARM64 removable EFI loader with `--no-nvram`.
- A failed/interrupted install is not reported as successful. Do not boot that
  target until installation succeeds. Do not disconnect either drive mid-install.

Reflashing identical images produces duplicate IDs initially, so the backend
regenerates filesystem/disk/partition identifiers and updates fstab, initramfs,
and GRUB before declaring success. The target's SSH host keys/machine ID are
generated on its first boot from the clean payload, not copied from the live USB.

## Checks

```bash
python3 -m unittest discover -s tests -v
shellcheck -x build/*.sh installer/*.sh openastro/*.sh tests/*.sh
```

The rootless tests exercise boot/mounted disk rejection, replacement races,
confirmation/cancellation, corrupt manifests/payloads, capacity checks, short
writes, and target read-back checks using **regular temporary files only**.
They do not prove hardware installation or protect against losing power.

On an ARM64/root build host, the additional integration test writes only a
private regular-file-backed **loop device**, then runs the shared EFI backend:

```bash
sudo tests/test-installer-loopback.sh images/openastro-orangepi6plus-branded.img.xz
```

Allow roughly 10 GiB free for that temporary test image. This exercises Linux
exclusive block I/O and read-back flushing without selecting a real disk;
physical SD/NVMe installation and boot still require separate confirmation.
