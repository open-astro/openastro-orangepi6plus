#!/bin/bash
# Shared ARM64 UEFI image preparation, 2026-10-23 (GPLv2).
# Callers set -euo pipefail and own the mount/loop cleanup trap.
UEFI_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uefi_fail() { echo "[uefi] $*" >&2; exit 1; }

prepare_uefi_partitions() {
    local device="$1" layout status=0 efinum
    layout=$(sfdisk --json "$device" | python3 "$UEFI_LIBDIR/image-layout.py")
    read -r ROOT ROOTNUM EFI <<< "$layout"
    [ "$(blkid -p -s TYPE -o value "$ROOT")" = ext4 ] || uefi_fail "Root must be ext4."
    [ "$(blkid -p -s TYPE -o value "$EFI")" = vfat ] || uefi_fail "EFI partition must be FAT."
    parted --script --fix "$device" resizepart "$ROOTNUM" 100%
    partprobe "$device"
    udevadm settle
    e2fsck -fy "$ROOT" || status=$?
    [ "$status" -le 2 ] || uefi_fail "Filesystem check failed (exit $status)."
    resize2fs "$ROOT"
    OLD_ROOT_UUID=$(blkid -p -s UUID -o value "$ROOT")
    OLD_EFI_UUID=$(blkid -p -s UUID -o value "$EFI")
    tune2fs -U random "$ROOT"
    fatlabel --volume-id --reset "$EFI"
    ROOT_UUID=$(blkid -p -s UUID -o value "$ROOT")
    EFI_UUID=$(blkid -p -s UUID -o value "$EFI")
    [ "$ROOT_UUID" != "$OLD_ROOT_UUID" ] && [ "$EFI_UUID" != "$OLD_EFI_UUID" ] || uefi_fail "UUID regeneration failed."
    efinum=${EFI#"$device"}
    efinum=${efinum#p}
    sfdisk --disk-id "$device" "$(cat /proc/sys/kernel/random/uuid)"
    sfdisk --part-uuid "$device" "$ROOTNUM" "$(cat /proc/sys/kernel/random/uuid)"
    sfdisk --part-uuid "$device" "$efinum" "$(cat /proc/sys/kernel/random/uuid)"
    partprobe "$device"
    udevadm settle
}

update_image_fstab() {
    local root="$1"
    [ "$(awk '$2 == "/" {print $1}' "$root/etc/fstab")" = "UUID=$OLD_ROOT_UUID" ] || uefi_fail "Expected UUID-based root fstab entry."
    sed -i -e "s|^[[:space:]]*UUID=${OLD_ROOT_UUID}[[:space:]]|UUID=$ROOT_UUID |" \
        -e "s|^[[:space:]]*UUID=${OLD_EFI_UUID}[[:space:]]|UUID=$EFI_UUID |" "$root/etc/fstab"
}

mount_uefi_image() {
    mkdir -p "$MNT"
    mount "$ROOT" "$MNT"
    mount --make-rprivate "$MNT"
    [ -f "$MNT/etc/armbian-release" ] || uefi_fail "Not an Armbian image."
    grep -qx 'VERSION_CODENAME=trixie' "$MNT/etc/os-release" || uefi_fail "Expected Debian Trixie."
    grep -qx 'ID=debian' "$MNT/etc/os-release" || uefi_fail "Expected Debian Trixie."
    [ "$(chroot "$MNT" dpkg --print-architecture)" = arm64 ] || uefi_fail "Expected ARM64."
    EFI_TARGET=$(awk -v uuid="UUID=$OLD_EFI_UUID" '$1 == uuid {print $2}' "$MNT/etc/fstab")
    case "$EFI_TARGET" in /boot|/boot/efi) ;; *) uefi_fail "Cannot identify EFI mount in fstab." ;; esac
    update_image_fstab "$MNT"
    EFI_MOUNT="$MNT$EFI_TARGET"
    mkdir -p "$EFI_MOUNT"
    mount "$EFI" "$EFI_MOUNT"
    [ -f "$EFI_MOUNT/EFI/BOOT/BOOTAA64.EFI" ] || uefi_fail "ARM64 removable-media EFI loader missing."
    mount -t proc proc "$MNT/proc"
    mount --bind /sys "$MNT/sys"
    mount -o remount,bind,ro "$MNT/sys"
    mount --bind /dev "$MNT/dev"
    mount --make-rprivate "$MNT/dev"
    mount -t devpts -o newinstance,ptmxmode=0666 devpts "$MNT/dev/pts"
}

refresh_uefi_boot() {
    chroot "$MNT" update-initramfs -u -k all
    chroot "$MNT" grub-install --target=arm64-efi --efi-directory="$EFI_TARGET" --no-nvram --removable
    chroot "$MNT" update-grub
}

unmount_image() {
    local path
    for path in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" "${EFI_MOUNT:-$MNT/boot/efi}" "$MNT"; do
        if mountpoint -q "$path"; then umount "$path" || return 1; fi
    done
    if [ -n "${LOOP:-}" ]; then losetup -d "$LOOP" || return 1; LOOP=""; fi
}
