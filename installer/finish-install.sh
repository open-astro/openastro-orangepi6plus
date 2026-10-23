#!/bin/bash
# Called only after payload read-back verification. No firmware/NVRAM writes.
set -euo pipefail
DEVICE="${1:?device required}"
EXPECTED_SEQ="${2:?disk sequence required}"
EXPECTED_SIZE="${3:?capacity required}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=build/uefi-image.sh
source "$HERE/uefi-image.sh"
[ "$(id -u)" -eq 0 ] && [ "$(uname -m)" = aarch64 ] || uefi_fail "Requires ARM64 root."
[ -b "$DEVICE" ] && [ "$(lsblk -dnro TYPE "$DEVICE")" = disk ] || uefi_fail "Expected a whole physical disk."
[ "$(cat "/sys/class/block/$(basename "$DEVICE")/diskseq")" = "$EXPECTED_SEQ" ] || uefi_fail "Target was replaced."
[ "$(blockdev --getsize64 "$DEVICE")" = "$EXPECTED_SIZE" ] || uefi_fail "Target capacity changed."
if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -E '[^[:space:]]' >/dev/null; then
    uefi_fail "Target is mounted/in use; refusing boot configuration."
fi
partprobe "$DEVICE"
udevadm settle
# Recheck after rereading the table in case an automounter claimed a partition.
if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -E '[^[:space:]]' >/dev/null; then
    uefi_fail "Target was automounted; refusing boot configuration."
fi
MNT=$(mktemp -d /mnt/openastro-install-XXXXXX)
EFI_MOUNT=""
LOOP=""
cleanup() {
    local status=$?
    if ! unmount_image; then
        echo "Unmount failed; target mounts retained at $MNT" >&2
        exit 1
    fi
    rmdir "$MNT"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
prepare_uefi_partitions "$DEVICE"
mount_uefi_image
refresh_uefi_boot
sync
