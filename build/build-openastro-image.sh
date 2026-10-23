#!/bin/bash
# OpenAstro Orange Pi 6 Plus port, modified 2026-10-23 (GPLv2).
# Customize a trusted Armbian Trixie ARM64 UEFI image on a native ARM64 host.
# Usage: sudo build/build-openastro-image.sh <stock-armbian.img[.xz]> [output.img.xz]
# Optional KERNEL_DEBS=<dir>: install matching ARM64 kernel packages.
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=build/uefi-image.sh
source "$REPODIR/build/uefi-image.sh"
SRC="${1:?usage: $0 <stock-armbian.img[.xz]> [output.img.xz]}"
OUT="${2:-$REPODIR/images/openastro-orangepi6plus.img.xz}"
log() { echo "[build] $*"; }
die() { echo "[build] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Must run as root."
[ "$(uname -m)" = aarch64 ] || die "Build host must be aarch64 (native chroot)."
[ -f "$SRC" ] || die "Source must be a regular .img or .img.xz file."
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || die "Output already exists; choose a new filename."
for cmd in python3 parted partprobe losetup blkid e2fsck resize2fs tune2fs fatlabel mount mountpoint findmnt chroot xz sha256sum sfdisk udevadm; do
    command -v "$cmd" >/dev/null || die "Missing build dependency: $cmd (see README)."
done

# Keep staging off small RAM-backed /tmp filesystems, especially on the board.
pick_workdir() {
    local d avail
    for d in "${TMPDIR:-}" "$REPODIR/images" /var/tmp /tmp; do
        [ -n "$d" ] || continue
        mkdir -p "$d" 2>/dev/null || continue
        [ -w "$d" ] || continue
        avail=$(df -Pk "$d" | awk 'NR==2{print $4}')
        if [ "${avail:-0}" -ge 12582912 ]; then echo "$d"; return 0; fi
    done
    return 1
}
WORKBASE="$(pick_workdir)" || die "Need at least 12 GiB free in TMPDIR, images/, /var/tmp, or /tmp."
WORK="$(mktemp -d "$WORKBASE/openastro-build-XXXXXX")"
IMG="$WORK/openastro.img"
MNT="$WORK/rootfs"
LOOP=""
EFI_MOUNT=""

cleanup() {
    local status=$?
    # Never delete through a busy mount or detach a still-mounted filesystem.
    if ! unmount_image; then
        echo "[build] Unmount failed; staging retained at $WORK" >&2
        exit 1
    fi
    if [ "$status" -eq 0 ]; then rm -rf -- "$WORK"
    else echo "[build] Build failed; staging retained at $WORK" >&2; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Staging source image (the source is never modified)..."
case "$SRC" in
    *.xz) xz -dc "$SRC" > "$IMG" ;;
    *) cp --reflink=auto "$SRC" "$IMG" ;;
esac
truncate -s +2G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
prepare_uefi_partitions "$LOOP"
mount_uefi_image
log "Root: $ROOT; EFI: $EFI at $EFI_TARGET; free space: $(df -h "$MNT" | awk 'NR==2{print $4}')"
log "New filesystem identifiers: root=$ROOT_UUID; EFI=$EFI_UUID"

RESOLV_LINK=$(readlink "$MNT/etc/resolv.conf" 2>/dev/null || true)
cp -a "$MNT/etc/resolv.conf" "$WORK/resolv.conf" 2>/dev/null || true
rm -f "$MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

# Do not start package services inside the chroot, or touch host EFI variables.
if [ -e "$MNT/usr/sbin/policy-rc.d" ] || [ -L "$MNT/usr/sbin/policy-rc.d" ]; then
    cp -a "$MNT/usr/sbin/policy-rc.d" "$WORK/policy-rc.d"
fi
rm -f "$MNT/usr/sbin/policy-rc.d"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
chmod 755 "$MNT/usr/sbin/policy-rc.d"
# Kernel package hooks must not probe/mount the build host's other disks.
install -d "$MNT/etc/default/grub.d"
printf 'GRUB_DISABLE_OS_PROBER=true\n' > "$MNT/etc/default/grub.d/99-openastro.cfg"

if [ -n "${KERNEL_DEBS:-}" ]; then
    shopt -s nullglob
    images=("$KERNEL_DEBS"/linux-image-*.deb)
    [ "${#images[@]}" -gt 0 ] || die "KERNEL_DEBS has no linux-image-*.deb."
    debs=("${images[@]}" "$KERNEL_DEBS"/linux-dtb-*.deb "$KERNEL_DEBS"/linux-headers-*.deb)
    install -d "$MNT/opt/kernel-debs"
    cp "${debs[@]}" "$MNT/opt/kernel-debs/"
    chroot "$MNT" /bin/bash -c 'dpkg -i /opt/kernel-debs/*.deb'
    rm -rf "$MNT/opt/kernel-debs"
fi

install -d "$MNT/opt/openastro"
install -m 0755 "$REPODIR"/openastro/*.sh "$MNT/opt/openastro/"
install -D -m 0644 "$REPODIR/openastro/assets/grub-background.png" "$MNT/opt/openastro/assets/grub-background.png"
log "Running OpenAstro setup..."
chroot "$MNT" /bin/bash -c 'cd /opt/openastro && ./openastro-setup.sh'
if [ -n "${OPENASTRO_INSTALLER_PAYLOAD:-}" ]; then
    "$REPODIR/build/stage-installer.sh" "$MNT" "$OPENASTRO_INSTALLER_PAYLOAD"
fi
refresh_uefi_boot

log "Cleaning image..."
chroot "$MNT" apt-get clean
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/var/log/* "$MNT"/tmp/*
install -d -m 2755 "$MNT/var/log/journal"
chroot "$MNT" chgrp systemd-journal /var/log/journal
rm -f "$MNT"/etc/ssh/ssh_host_*
rm -f "$MNT/var/lib/systemd/random-seed"
: > "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"
rm -f "$MNT/etc/resolv.conf"
if [ -n "$RESOLV_LINK" ]; then ln -s "$RESOLV_LINK" "$MNT/etc/resolv.conf"
elif [ -f "$WORK/resolv.conf" ]; then cp "$WORK/resolv.conf" "$MNT/etc/resolv.conf"; fi
rm -f "$MNT/usr/sbin/policy-rc.d"
if [ -e "$WORK/policy-rc.d" ] || [ -L "$WORK/policy-rc.d" ]; then
    cp -a "$WORK/policy-rc.d" "$MNT/usr/sbin/policy-rc.d"
fi

log "Zero-filling free space for compression..."
dd if=/dev/zero of="$MNT/ZERO.fill" bs=4M status=none 2>/dev/null || true
sync
rm -f "$MNT/ZERO.fill"
sync
unmount_image

log "Compressing -> $OUT"
mkdir -p "$(dirname "$OUT")"
TEMP_OUT=$(mktemp "${OUT}.partial-XXXXXX")
if ! xz -T0 -6 -c "$IMG" > "$TEMP_OUT"; then
    rm -f "$TEMP_OUT"
    die "Compression failed."
fi
chmod 0644 "$TEMP_OUT"
mv -nT "$TEMP_OUT" "$OUT"
[ ! -e "$TEMP_OUT" ] || die "Output appeared during build; compressed image retained at $TEMP_OUT."
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
