#!/bin/bash
# Orange Pi 6 Plus port, 2026-10-23 (GPLv2).
# Run before NetworkManager; do not assume a radio or interface name.
set -euo pipefail

select_radio() {
    local iface info capabilities
    local -a interfaces
    mapfile -t interfaces < <(iw dev | awk '$1 == "Interface" && $2 != "ap0" {print $2}')
    for iface in "${interfaces[@]}"; do
        [ -z "${AP_INTERFACE:-}" ] || [ "$iface" = "$AP_INTERFACE" ] || continue
        [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || continue
        info=$(iw dev "$iface" info) || continue
        PHY=$(awk '$1 == "wiphy" {print "phy" $2}' <<< "$info")
        [[ "$PHY" =~ ^phy[0-9]+$ ]] || continue
        capabilities=$(iw phy "$PHY" info) || continue
        grep -E '^[[:space:]]+\* AP$' <<< "$capabilities" >/dev/null || continue
        MAC=$(awk '$1 == "addr" {print $2}' <<< "$info")
        [[ "$MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || continue
        WIFI_INTERFACE="$iface"
        return 0
    done
    return 1
}

create_ap_interface() {
    local first last ap_phy
    if ip link show ap0 >/dev/null 2>&1; then
        ap_phy=$(iw dev ap0 info | awk '$1 == "wiphy" {print "phy" $2}')
        [ "$ap_phy" = "$PHY" ] || { echo "ap0 belongs to another radio" >&2; return 1; }
    elif ! iw phy "$PHY" interface add ap0 type __ap; then
        # Drivers without virtual-interface support can still provide an AP.
        echo "[openastro] No virtual AP support; using $WIFI_INTERFACE (AP or client, not both)." >&2
        AP_DEVICE="$WIFI_INTERFACE"
        return 0
    fi
    first=$(( (0x${MAC%%:*} | 0x02) & 0xfe ))
    last=$(( 0x${MAC##*:} ^ 0x80 ))
    # Changing the tail also avoids collision when the parent MAC is already local.
    ip link set ap0 address "$(printf '%02x' "$first")${MAC:2:12}:$(printf '%02x' "$last")"
    AP_DEVICE=ap0
}

configure_profile() {
    local profile="$1" marker="$2" suffix ssid
    sed -i "s/^interface-name=.*/interface-name=$AP_DEVICE/" "$profile"
    if [ ! -f "$marker" ]; then
        suffix=${MAC//:/}
        suffix=${suffix: -4}
        suffix=${suffix^^}
        ssid=$(sed -n 's/^ssid=//p' "$profile")
        if [ "${ssid: -5}" != "-$suffix" ]; then
            sed -i "s/^ssid=.*/&-$suffix/" "$profile"
        fi
        mkdir -p "$(dirname "$marker")"
        touch "$marker"
    fi
}

main() {
    local _
    AP_INTERFACE=""
    AP_COUNTRY=00
    # Root-owned settings written by openastro-setup.sh.
    if [ -f /etc/default/openastro-ap ]; then
        # shellcheck source=/dev/null
        source /etc/default/openastro-ap
    fi
    for _ in {1..30}; do
        if select_radio; then break; fi
        sleep 1
    done
    if [ -z "${WIFI_INTERFACE:-}" ]; then
        echo "[openastro] No AP-capable WiFi adapter found; Ethernet remains available." >&2
        return 0
    fi
    iw reg set "$AP_COUNTRY" || echo "[openastro] Could not set regulatory country; driver policy still applies." >&2
    create_ap_interface
    configure_profile /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection /var/lib/openastro/ssid-set
    echo "[openastro] Hotspot interface: $AP_DEVICE; radio: $PHY; parent: $WIFI_INTERFACE."
    echo "[openastro] AP+client concurrency and channels are limited by this adapter's driver."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
