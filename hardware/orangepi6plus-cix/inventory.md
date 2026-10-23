# Orange Pi 6 Plus — hardware inventory

Port started 2026-10-23. **Native build, offline inspection, and branded SD
boot/basic runtime checks passed; hotspot client and equipment tests remain pending.** Do not
inherit the Orange Pi 4 Pro's validation claims, kernel, or WiFi assumptions.

| Item | Target / evidence |
|------|-------------------|
| Board / SoC | Orange Pi 6 Plus, CIX CD8180/CD8160 (Sky1), ARM64 |
| Boot firmware | Board UEFI in SPI; not modified by this repository |
| Boot media | Separate microSD, GPT with FAT ESP and ext4 root; do not overwrite build host media |
| Base inspected | Armbian 26.8.3, Debian 13 Trixie, `6.18.45-current-arm64` |
| Armbian identity in that image | `BOARD=uefi-arm64`, `BOARDFAMILY=uefi-arm64` |
| ESP / root | Partition 1: FAT, UUID `64E6-C5C0`, `/boot/efi`; partition 2: ARM64 root GUID, ext4 |
| WiFi target | Intel AX210 NGW M.2 card, PCIe `iwlwifi` / `iwlmvm` |
| Bluetooth | AX210 USB transport; needs the slot's USB connection and firmware |
| Ethernet | Two ports, DHCP via NetworkManager; interface names discovered by NM |
| Power / cooling | Use the board vendor's specified supply and active cooling for native builds |

The [official Armbian board download](https://armbian.com/boards/orangepi6-plus)
currently resolves to the generic UEFI image above. Newer Armbian sources also
have a separate `cix-acpi` board configuration and `cix-p1` kernel family;
those are **not** the identity of the inspected release. Do not blindly use
`BOARD=orangepi6plus`, copy an Allwinner DTB, or replace working board firmware.

## WiFi constraints

- Initial hotspot: 2.4 GHz, channel 6. AX210 Linux AP operation does not
  support 5/6 GHz; setting a country does not remove this limit.
- `iwlmvm` in Linux 6.18 advertises managed + AP with **one shared channel**.
  This is not the 4 Pro's validated multi-channel AP+client configuration.
- Other cards must have a working kernel driver, firmware, AP mode, and
  suitable interface combinations. The boot helper supports different
  physical interface/PHY names; no promise is made for unsupported cards.
- Ethernet is the recovery/uplink path. An independent WiFi client uplink
  may need a second radio. Test actual NetworkManager/AlpacaBridge behavior.

## Kernel / ZWO evidence

The downloaded rootfs kernel config has `CONFIG_HIDRAW=y`,
`CONFIG_USB_HIDDEV=y`, `CONFIG_IWLWIFI=m`, `CONFIG_IWLMVM=m`, and `CONFIG_R8169=m`.
The [Linux stable 6.18.45 source](https://github.com/gregkh/linux/blob/v6.18.45/drivers/hid/usbhid/hid-core.c)
contains the `bNumDescriptors` repair. No custom kernel is required solely
for those options/fix. Test real devices before claiming support.

The portable config fragment and original backport are retained in
[`kernel/`](kernel/README.md) as reference inputs; they are not reapplied to
the already-fixed stock kernel.

## Build-host observations (2026-10-23)

The board reached over SSH is running ARM64 Armbian 26.8.3 Trixie with
`6.18.45-current-arm64`. Its WiFi interface is `wlp1s0`; `iw list` reports
managed + AP on one shared channel. The running base kernel config enables
both HID options, and its actual `usbhid.ko` binary contains the descriptor
repair diagnostic (`fixing wrong optional hid class descriptors count`).
These observations validate the build host/base kernel, **not** a boot of
the customized image. The host root is `/dev/sda2`; its disks must not be
overwritten while building or testing another image.

The first native build completed and its checksum verified on the board.
Read-only inspection confirmed AlpacaBridge 5.0.0, NetworkManager 1.52.1,
Intel firmware, both HID options and the compiled USB HID descriptor fix,
enabled SSH/AP/AlpacaBridge services, and cleared machine ID/SSH host keys.
The extracted ext4 filesystem passed `e2fsck -fn`.

That first artifact is archived under `images/first-build/`, **not for boot
testing**: it retained the same filesystem UUIDs as the host's running USB
installation. The builder now regenerates filesystem/GPT identifiers and
refreshes fstab, initramfs, the removable EFI loader (without NVRAM writes),
and GRUB.

The corrected native build completed and passed checksum verification on
both the board and workstation, read-only ext4/FAT checks, and inspection
of packages, enabled services, GRUB root selection, and the compiled HID fix.
It is ready for a **boot test on separate media**, not yet a validated release.

| Corrected artifact | Value |
|--------------------|-------|
| File | `images/openastro-orangepi6plus.img.xz` |
| Compressed / raw size | 405,820,908 / 7,293,894,656 bytes |
| SHA256 | `d84aa0e4a32f65af4cf53ee6cb440c226695f1725a57802461d9d97792bfc452` |
| Root UUID | `78fc9d28-6b9e-4a33-86a8-23f4acdea10c` |
| EFI UUID | `E913-7E92` |

Build log and machine-readable inspection results are saved locally in
`images/build-native.log` and `images/verification.json` (ignored by Git).

### First physical boot test: blocked before GRUB

The stock Armbian card boots automatically, but the OpenAstro card returns
to firmware setup. UEFI Shell reports USB block devices but no `FS0:` FAT
filesystem. Raspberry Pi Imager was used with the compressed image.
The local OpenAstro artifact has valid GPT header/partition CRCs, valid FAT
boot/backup sectors, and a `BOOTAA64.EFI` identical to the stock artifact
(SHA256 `4ae4d05b737d3077841b24f6932d8dd2738ecb4928d376e7ebe8aa8f1159faa7`).
Initial workstation inspection showed one empty exFAT partition. After
reflashing and reinserting the card reader to refresh its partition table,
the card exposes the expected 260 MiB FAT ESP and ext4 root, with the exact
filesystem and partition UUIDs of the verified image.

Read-only mounted-card checks confirmed the EFI loader hash, fstab UUIDs,
kernel/initramfs files, 48-bit VA and HID config, compiled ZWO fix, enabled
AP/SSH/AlpacaBridge services, installed scripts, and cleared first-boot
identity. Mounted-card `grub.cfg` is root-only and was not reread; its image
copy passed earlier inspection. A new physical boot test is still pending;
no firmware-setting change has been made. This was not a Linux locale prompt.

### Reflashed-card boot: successful, root-autologin fix pending

The user confirmed the OpenAstro card boots into Linux and auto-logs in as
root. Image inspection found factory `--autologin root` getty overrides;
Armbian normally deletes these in the first-login wizard we intentionally
skip. Setup now removes matching factory overrides, with rootless regression
tests. The original unbranded artifact lacks this fix; the newer branded
artifact below includes it. Service, network, and device validation
remain pending. Do not publish this artifact as a validated release.

### Branded image and installer development

`images/openastro-orangepi6plus-branded.img.xz` has now been built natively
and inspected offline. SHA256:
`1a81f5d9ab2265c369acf231934549e86760b50e04fcb8236ee249b2b4caca4c`.
The artifact contains the OpenAstro background/menu title, no factory root
autologin overrides, the 48-bit/HID options, and the compiled descriptor fix.
Its ext4 check passed. The user subsequently flashed and booted this image;
read-only runtime results are recorded below. Visual branding still needs
confirmation. No running configuration was patched in place.

The USB installer uses this clean image as its offline payload and shares
the UEFI preparation code with the normal builder. Rootless safety tests
pass. A read-only candidate probe on the actual board excluded its running
SD disk and listed only `/dev/nvme0n1` (NE-256 2280, 256,060,514,304 bytes).
**No real NVMe/SD installation has been performed.** Native ARM64 loopback
integration passed: payload write and block-device read-back/flush, root
growth, unique filesystem/GPT IDs, fstab, initramfs, and removable EFI loader.
That test wrote only a private file-backed loop device and removed its
staging after unmounting. Its output is retained in
`images/installer-loopback.log`. The separate installer image build and
physical menu/installation/boot tests remain distinct validation steps.

The installer image has now been built natively and copied to the workstation:
`images/openastro-orangepi6plus-installer.img.xz` (801,795,144 bytes), SHA256
`12756d9529cd5554c29916fdc160481ab68ef62b5c265bde5118ff1952c1a278`.
The embedded payload hashes match the verified branded normal image exactly.
GPT/FAT/ext4 checks, installer code and service contents, carrier-only service
masks, unique IDs, EFI loader, branding, and HID/48-bit requirements passed
offline inspection. No authentication keys or pre-generated host keys are
baked into either image. Results/logs are in `images/verification-installer.json`
and `images/build-installer.log`.

The carrier deliberately disables SSH and AlpacaBridge: its first version is
a local keyboard/monitor installer. The installed normal payload retains
both. **The installer console and real disk installation still require
physical testing; no NVMe/SD has been erased by the agent.**

### Branded SD runtime validation (2026-10-23)

The user confirmed the fresh SSH host fingerprint before password-only
diagnostics at `192.168.4.37`. No authentication keys were installed and
no board configuration was changed.

- Running root `/dev/sda2` has the branded UUID
  `3910ed9f-96ac-4a33-81dd-d761cda8c50c`; it expanded to 115 GiB
  (112 GiB available). Kernel is `6.18.45-current-arm64` with 48-bit VA
  and both required HID options enabled.
- tty1 getty has no root-autologin argument. Password SSH works; SSH,
  NetworkManager, AlpacaBridge, and Avahi services are active. Client-side
  mDNS resolution and fresh-device identity uniqueness remain untested.
- Ethernet `enp97s0` obtained `192.168.4.37`; the other port `enp49s0`
  is down and has not been tested independently.
- AX210 hotspot `OpenAstro-7A7E` is active on `ap0`, 2.4 GHz channel 6,
  at `172.24.1.1/24`. dnsmasq listens for DHCP/DNS and nftables contains
  `ip nm-shared-ap0`. These are server-side checks, not proof of client
  association, DHCP, DNS, application access, or internet forwarding.
- AlpacaBridge returns HTTP 200 locally. Its management description reports
  version 5.0.0 and a synchronized clock; configured devices are empty.
  No astronomy equipment is attached, so device operation remains untested.
- Installed GRUB background matches the generated asset (SHA256
  `1a45cbd6273f8514e10abd082ed3d6dcd042178c2fe47956a59403595a3efc10`);
  actual on-screen artwork still needs user confirmation.

The user subsequently confirmed hotspot association, access to AlpacaBridge
at `http://172.24.1.1:6800`, and internet browsing through the Ethernet uplink
using the client test above. Hotspot client DHCP/DNS/NAT now have end-to-end
validation. The user also confirmed the OpenAstro GRUB artwork appeared.

The physical USB installer menu and real target installation remain untested.
These results do not authorize any disk erase or a commit/push.

### Physical USB installer and NVMe boot validation

The user completed the USB installer onto NVMe and confirmed boot with both
SD and installer USB removed. The new ED25519 host fingerprint was confirmed
before password-only, read-only diagnostics at `192.168.4.37`.

- Root: `/dev/nvme0n1p2`, UUID `13590adc-3ead-4a5e-af63-52260129b463`.
- EFI: `/dev/nvme0n1p1`, UUID `FCC9-423E`; fstab matches both fresh IDs.
- NVMe capacity is 238.5 GiB; root partition fills the drive, with a 235 GiB
  filesystem and 228 GiB free.
- Kernel `6.18.45-current-arm64` retains 48-bit VA and both HID options.
- Password SSH, NetworkManager, AlpacaBridge, and Avahi are active; tty1
  getty has no root-autologin argument. No installer service is present.
- Ethernet DHCP works; hotspot `ap0` is active at `172.24.1.1/24`.
  AlpacaBridge management responds without errors, version 5.0.0, clock
  synchronized, and no configured devices.

The user subsequently confirmed hotspot client access after NVMe installation.
This supersedes the earlier physical-installer pending notes. Physical SD
installation and astronomy equipment remain untested. No configuration changes, authentication keys, commits, or
pushes were made during validation.

## Acceptance checklist — before committing/publishing

Local checks on 2026-10-23 (x86_64, no root): 12 Python tests, mocked WiFi
helper checks, Bash syntax, and ShellCheck passed. The source image's SHA256
was verified. Growing a separate copy with `parted --script --fix` preserved
the ESP byte-for-byte, grew only root, and passed the layout parser. These
checks are **not** a native build or a boot test.

- [ ] Stock Armbian image boots on this board; record UEFI version/settings.
- [x] Native build completes on the 6 Plus, including package installation and output checksum.
- [x] Customized image boots from a separate microSD with existing NVMe disks left untouched.
- [ ] Root auto-expansion works; ESP/GRUB remain bootable after reboot and kernel update.
- [ ] Login works without the Armbian first-login wizard; SSH keys and machine IDs differ between fresh devices.
- [ ] SSH works on first boot; mDNS resolves `openastro.local` on a supporting LAN.
- [ ] Each Ethernet port obtains DHCP independently; repeat with both connected.
- [ ] AX210 firmware loads; actual interface name and `iw list` combinations recorded.
- [x] Hotspot `OpenAstro-XXXX` appears, accepts the password, and provides DHCP/DNS at `172.24.1.1`.
- [ ] Hotspot clients can reach AlpacaBridge on port 6800 with no internet uplink.
- [x] Hotspot clients get internet through Ethernet (DHCP, DNS, and NAT).
- [ ] WiFi client mode works; test same-channel AP+client and document the actual behavior.
- [ ] If required, test an independent client uplink using a second radio.
- [ ] Alternate AP-capable adapter works without hard-coded `wlan0`/`phy0`; missing radio leaves Ethernet usable.
- [ ] Bluetooth enumerates with `bluetoothctl list`; test if needed for equipment.
- [ ] ZWO camera/EAF/EFW enumerate, and AlpacaBridge can open them as its service user.
- [ ] ASCOM ConformU succeeds for available equipment.
- [ ] `apt update` / `apt upgrade` work and leave the next boot operational.
- [ ] Cold boot, reboot, and persistent logs work; change default passwords before using untrusted networks.

Record results here with dates and actual kernel/firmware/adapter versions.
