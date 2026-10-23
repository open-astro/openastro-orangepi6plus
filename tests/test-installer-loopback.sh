#!/bin/bash
# ARM64/root integration test. All writes are confined to a private image file.
set -euo pipefail
REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="${1:?usage: $0 <verified-normal-openastro.img.xz>}"
[ "$(id -u)" -eq 0 ] && [ "$(uname -m)" = aarch64 ] || { echo 'Requires native ARM64 root.' >&2; exit 1; }
[ -f "$PAYLOAD" ] || exit 1
# shellcheck source=build/uefi-image.sh
source "$REPODIR/build/uefi-image.sh"
mkdir -p "$REPODIR/images"
WORK=$(mktemp -d "$REPODIR/images/installer-loopback-XXXXXX")
MNT="$WORK/rootfs"
EFI_MOUNT=""
LOOP=""
cleanup() {
    local status=$?
    if ! unmount_image; then
        echo "Unmount failed; test staging retained at $WORK" >&2
        exit 1
    fi
    if [ "$status" -eq 0 ]; then rm -rf -- "$WORK"
    else echo "Failed test staging retained at $WORK" >&2; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 "$REPODIR/build/installer-manifest.py" "$PAYLOAD" > "$WORK/manifest.json"
BYTES=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["image_bytes"])' "$WORK/manifest.json")
truncate -s "$((BYTES + 128 * 1024 * 1024))" "$WORK/target.img"
LOOP=$(losetup --find --show --partscan "$WORK/target.img")
[[ "$LOOP" =~ ^/dev/loop[0-9]+$ ]] || exit 1
[ "$(losetup --noheadings --output BACK-FILE "$LOOP")" = "$WORK/target.img" ] || exit 1
python3 - "$REPODIR" "$PAYLOAD" "$WORK/manifest.json" "$LOOP" <<'PY'
import importlib.util,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('installer',Path(sys.argv[1])/'installer/openastro-install.py')
installer=importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
meta=installer.load_manifest(Path(sys.argv[3]))
with open(sys.argv[2],'rb') as stream:
    installer.verify_payload(stream,meta)
    fd=os.open(sys.argv[4],os.O_RDWR|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        capacity=os.lseek(fd,0,os.SEEK_END)
        installer.write_and_verify(stream,fd,capacity,meta)
    finally:
        os.close(fd)
PY
partprobe "$LOOP"
udevadm settle
prepare_uefi_partitions "$LOOP"
mount_uefi_image
refresh_uefi_boot
grep -F "root=UUID=$ROOT_UUID" "$MNT/boot/grub/grub.cfg" >/dev/null
grep -F 'OpenAstro GNU/Linux' "$MNT/boot/grub/grub.cfg" >/dev/null
[ "$(blkid -p -s UUID -o value "$ROOT")" = "$ROOT_UUID" ]
[ "$(blkid -p -s UUID -o value "$EFI")" = "$EFI_UUID" ]
[ ! -s "$MNT/etc/machine-id" ]
[ ! -e "$MNT/etc/systemd/system/getty@.service.d/override.conf" ]
[ ! -e "$MNT/etc/systemd/system/openastro-installer.service" ]
echo 'Loopback raw write/read-back, unique IDs, fstab, initramfs, and EFI configuration passed.'
