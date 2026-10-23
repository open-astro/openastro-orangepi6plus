#!/bin/bash
# Rootless checks: mock only hardware commands, exercise the installed helper.
set -euo pipefail
REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=openastro/openastro-ap-iface.sh
source "$REPODIR/openastro/openastro-ap-iface.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/openastro-wifi-test-XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

AP_INTERFACE=""
VIRTUAL_SUPPORTED=yes
EXISTING_AP=no
PHY_SUPPORTED=yes

iw() {
    case "$*" in
        dev) printf 'phy#7\n\tInterface wlp7s0\nphy#3\n\tInterface wlan3\n' ;;
        'dev wlp7s0 info') printf 'Interface wlp7s0\n\taddr 00:11:22:33:44:55\n\twiphy 7\n' ;;
        'dev wlan3 info') printf 'Interface wlan3\n\taddr 02:11:22:33:AB:CD\n\twiphy 3\n' ;;
        'phy phy7 info') printf 'Supported interface modes:\n\t * managed\n' ;;
        'phy phy3 info')
            if [ "$PHY_SUPPORTED" = yes ]; then printf 'Supported interface modes:\n\t * managed\n\t * AP\n'; fi ;;
        'phy phy3 interface add ap0 type __ap') [ "$VIRTUAL_SUPPORTED" = yes ] ;;
        'dev ap0 info') printf 'Interface ap0\n\twiphy 9\n' ;;
        *) echo "Unexpected iw invocation: $*" >&2; return 1 ;;
    esac
}
ip() {
    case "$*" in
        'link show ap0') [ "$EXISTING_AP" = yes ] ;;
        'link set ap0 address '*) printf '%s\n' "${*:5}" > "$WORK/ap-mac" ;;
        *) echo "Unexpected ip invocation: $*" >&2; return 1 ;;
    esac
}

select_radio
[ "$WIFI_INTERFACE" = wlan3 ] && [ "$PHY" = phy3 ] && [ "$MAC" = 02:11:22:33:AB:CD ]
AP_INTERFACE=wlp7s0
if select_radio; then echo 'Selected a radio without AP mode' >&2; exit 1; fi
AP_INTERFACE=wlan3
select_radio
create_ap_interface
[ "$AP_DEVICE" = ap0 ]
[ "$(cat "$WORK/ap-mac")" = 02:11:22:33:AB:4d ]

cat > "$WORK/profile" <<'EOF'
[connection]
interface-name=ap0
[wifi]
ssid=OpenAstro
EOF
configure_profile "$WORK/profile" "$WORK/state/ssid-set"
configure_profile "$WORK/profile" "$WORK/state/ssid-set"
grep -qx 'ssid=OpenAstro-ABCD' "$WORK/profile"
rm "$WORK/state/ssid-set"
configure_profile "$WORK/profile" "$WORK/state/ssid-set"
grep -qx 'ssid=OpenAstro-ABCD' "$WORK/profile"

VIRTUAL_SUPPORTED=no
create_ap_interface
[ "$AP_DEVICE" = wlan3 ]
configure_profile "$WORK/profile" "$WORK/state/ssid-set"
grep -qx 'interface-name=wlan3' "$WORK/profile"

EXISTING_AP=yes
if create_ap_interface; then echo 'Reused ap0 on a different radio' >&2; exit 1; fi
PHY_SUPPORTED=no
if select_radio; then echo 'Selected unsupported hardware' >&2; exit 1; fi
echo 'WiFi checks passed (radio discovery, MAC, SSID, fallback, and mismatched PHY).'
