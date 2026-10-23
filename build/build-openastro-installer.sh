#!/bin/bash
# Build a separate USB installer from a normal OpenAstro image (GPLv2).
set -euo pipefail
REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="${1:?usage: $0 <openastro.img.xz> [installer.img.xz]}"
[ -f "$PAYLOAD" ] && [[ "$PAYLOAD" = *.img.xz ]] || { echo 'Expected a normal OpenAstro .img.xz image.' >&2; exit 1; }
export OPENASTRO_INSTALLER_PAYLOAD
OPENASTRO_INSTALLER_PAYLOAD=$(realpath "$PAYLOAD")
exec "$REPODIR/build/build-openastro-image.sh" "$OPENASTRO_INSTALLER_PAYLOAD" \
    "${2:-$REPODIR/images/openastro-orangepi6plus-installer.img.xz}"
