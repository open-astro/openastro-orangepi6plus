#!/bin/bash
# Add an offline installer to a private staged image, never the build host.
set -euo pipefail
MNT=$(realpath "${1:?staged root required}")
PAYLOAD="${2:?payload required}"
REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$PAYLOAD" ] && [[ "$PAYLOAD" = *.img.xz ]] || { echo 'Expected a normal OpenAstro .img.xz payload.' >&2; exit 1; }
if [ "$MNT" = / ] || ! mountpoint -q "$MNT"; then
    echo 'Expected a private loop-mounted staged root, never the running system.' >&2
    exit 1
fi
SOURCE=$(findmnt --noheadings --output SOURCE --mountpoint "$MNT")
[[ "$SOURCE" =~ ^/dev/loop[0-9]+p[0-9]+$ ]] || { echo 'Expected a private loop-mounted staged root.' >&2; exit 1; }
chroot "$MNT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 parted e2fsprogs dosfstools util-linux fdisk udev xz-utils kmod
install -D -m 0644 "$PAYLOAD" "$MNT/opt/openastro-installer/payload.img.xz"
python3 "$REPODIR/build/installer-manifest.py" "$PAYLOAD" > "$MNT/opt/openastro-installer/manifest.json"
install -D -m 0755 "$REPODIR/installer/openastro-install.py" "$MNT/usr/local/sbin/openastro-install"
install -D -m 0755 "$REPODIR/installer/finish-install.sh" "$MNT/usr/lib/openastro-installer/finish-install.sh"
install -m 0644 "$REPODIR/build/uefi-image.sh" "$REPODIR/build/image-layout.py" "$MNT/usr/lib/openastro-installer/"
install -D -m 0644 "$REPODIR/installer/openastro-installer.service" "$MNT/etc/systemd/system/openastro-installer.service"
printf 'GRUB_DISTRIBUTOR="OpenAstro Installer"\n' > "$MNT/etc/default/grub.d/99-openastro-installer.cfg"
printf 'openastro-installer\n' > "$MNT/etc/hostname"
sed -i 's/^127\.0\.1\.1.*/127.0.1.1\topenastro-installer/' "$MNT/etc/hosts"
# Only the carrier boots the privileged menu. The bundled normal image is unchanged.
chroot "$MNT" systemctl mask getty@tty1.service alpacabridge.service udisks2.service ssh.service ssh.socket
chroot "$MNT" systemctl enable openastro-installer.service
