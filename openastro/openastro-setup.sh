#!/bin/bash
# OpenAstro layer for the Orange Pi 6 Plus (CIX CD8180/CD8160).
# Modified 2026-10-23 for this port; licensed under GPLv2.
#
# This turns a stock Armbian ARM64 UEFI image (Debian 13 Trixie minimal
# CLI, current kernel) into the OpenAstro OS: a WiFi access point
# (OpenAstro / 12345678), baked-in credentials (astro/astro, no first-boot
# wizard), and the plumbing AlpacaBridge expects. The OS runs from the microSD
# card - there is no eMMC/SPI install step. On first boot the SSID gains a
# per-board suffix from the selected WiFi MAC (e.g. OpenAstro-915D) so multiple
# boards don't collide.
#
# AlpacaBridge is preinstalled from the OpenAstro apt repository
# (apt.openastro.net) and stays current with apt upgrade.
#
# AX210 is the initial target, but the AP helper discovers other adapters.
# Concurrency is driver-dependent: Intel AP+client uses one shared channel,
# and Intel AP mode is limited to 2.4 GHz. Do not assume 4 Pro WiFi behavior.
#
# Re-running resets credentials and networking. Run as root in the image-build chroot
# (build/build-openastro-image.sh) or post-flash on a booted board.

set -euo pipefail
export LC_ALL=C

# --- Config (override via env) ---
AP_SSID="${AP_SSID:-OpenAstro}"
AP_PASSPHRASE="${AP_PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-172.24.1.1}"                # pinned (not NM's 10.42.0.1 default) so docs can give a fixed bridge IP
AP_BAND="${AP_BAND:-bg}"                    # AX210 AP mode supports 2.4 GHz only
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_COUNTRY="${AP_COUNTRY:-00}"              # set your actual country, never guess it
AP_INTERFACE="${AP_INTERFACE:-}"            # optional parent interface; otherwise discover an AP-capable adapter
OA_HOSTNAME="${OPENASTRO_HOSTNAME:-openastro}"
OA_USER="${OPENASTRO_USER:-astro}"
OA_PASS="${OPENASTRO_PASS:-astro}"
SETUPDIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[openastro] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }
fail() { echo "[openastro] $*" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = arm64 ] || fail "Expected ARM64."
if ! grep -qx 'ID=debian' /etc/os-release || ! grep -qx 'VERSION_CODENAME=trixie' /etc/os-release; then
    fail "Expected Debian Trixie."
fi
[ -f "$SETUPDIR/openastro-ap-iface.sh" ] || fail "Missing companion openastro-ap-iface.sh."
[ -f "$SETUPDIR/assets/grub-background.png" ] || fail "Missing OpenAstro GRUB artwork."
# Keep values safe for the NetworkManager keyfile and per-board suffix.
[[ "$AP_SSID" =~ ^[a-zA-Z0-9][a-zA-Z0-9\ ._-]{0,26}$ ]] || fail "SSID must be 1-27 simple ASCII characters (letters, digits, spaces, ._-)."
[ "${#AP_PASSPHRASE}" -ge 8 ] && [ "${#AP_PASSPHRASE}" -le 63 ] || fail "AP passphrase must be 8-63 characters."
[[ ! "$AP_PASSPHRASE" =~ [[:cntrl:]] && "$AP_PASSPHRASE" != *\\* && "$AP_PASSPHRASE" != ' '* && "$AP_PASSPHRASE" != *' ' ]] || fail "AP passphrase cannot contain control characters, backslashes, or edge spaces."
[[ "$AP_COUNTRY" =~ ^([A-Z]{2}|00)$ ]] || fail "AP_COUNTRY must be an uppercase two-letter country code or 00."
[[ "$AP_BAND" = bg || "$AP_BAND" = a ]] || fail "AP_BAND must be bg or a."
[[ "$AP_CHANNEL" =~ ^[1-9][0-9]{0,2}$ ]] || fail "Invalid AP channel."
[[ -z "$AP_INTERFACE" || "$AP_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail "Invalid parent interface."
[[ "$AP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "AP_IP must be an IPv4 address."
IFS=. read -r -a octets <<< "$AP_IP"
[ "${#octets[@]}" -eq 4 ] || fail "AP_IP must be an IPv4 address."
for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$octet" -le 255 ] || fail "Invalid AP_IP."
done
[ "${octets[3]}" -gt 0 ] && [ "${octets[3]}" -lt 255 ] || fail "AP_IP must be a host in its /24 subnet."
[[ "$OA_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail "Invalid hostname."
[[ "$OA_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "Invalid username."
[[ -n "$OA_PASS" && ! "$OA_PASS" =~ [[:cntrl:]:] ]] || fail "Login password cannot be empty or contain colons/control characters."

# ============================================================
# Packages
# ============================================================
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# dnsmasq-base and wpasupplicant must be explicit: NM's shared/AP mode needs
# both, but they are only Recommends of network-manager and Armbian minimal
# disables recommends. Without dnsmasq the AP flaps forever with "could not
# start dnsmasq"; without wpa_supplicant NM leaves every wifi device
# "unavailable" and the AP never activates at all (wpasupplicant currently
# rides in with the Armbian base image, but that is not a contract - the
# rk3568 image shipped broken wifi from exactly this assumption).
# nftables is equally load-bearing: NM's shared mode builds its NAT/masquerade
# with it (or iptables), and Armbian minimal ships NEITHER - without one of
# them hotspot clients get DHCP+DNS but silently no internet.
apt-get install -y -qq \
    network-manager wpasupplicant polkitd dnsmasq-base nftables iw wireless-regdb \
    ca-certificates curl gnupg iproute2 openssh-server sudo avahi-daemon bluez \
    firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-mediatek firmware-realtek \
    >/dev/null

# GRUB branding; board firmware and the kernel's compiled-in logo are separate.
install -D -m 0644 "$SETUPDIR/assets/grub-background.png" /usr/share/images/openastro/grub-background.png
cat > /etc/default/grub.d/99-openastro-branding.cfg <<'EOF'
GRUB_DISTRIBUTOR="OpenAstro"
GRUB_BACKGROUND="/usr/share/images/openastro/grub-background.png"
EOF

# ============================================================
# Networking (NetworkManager manages everything - fleet standard)
# ============================================================
# NM owns all interfaces: both Ethernet ports get DHCP and WiFi runs the AP.
# The AP is an NM keyfile
# connection with mode=ap and ipv4.method=shared - NM's internal dnsmasq
# serves DHCP/DNS and sets up NAT to whatever uplink exists, replacing the
# old hostapd + dnsmasq + iptables stack. AlpacaBridge's WiFi manager drives
# this same NM setup over D-Bus (polkitd authorizes it; the polkit rule
# ships in the AlpacaBridge .deb).
log "Configuring networking (NetworkManager)..."

# Retire the old NM/networkd split (earlier layers unmanaged end0).
rm -f /etc/NetworkManager/conf.d/10-openastro-unmanaged.conf
# Armbian drives ethernet through netplan's networkd renderer; hand the whole
# stack to NM instead and stop networkd so the two don't fight over end0.
if [ -d /etc/netplan ]; then
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/10-openastro.yaml <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
    chmod 600 /etc/netplan/10-openastro.yaml
fi
systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service >/dev/null 2>&1 || true

# Virtual ap0 is preferred; AP-only drivers fall back to their physical interface.
install -m 0755 "$SETUPDIR/openastro-ap-iface.sh" /usr/local/sbin/openastro-ap-iface
install -d /etc/default /etc/NetworkManager/conf.d
printf 'AP_INTERFACE=%q\nAP_COUNTRY=%q\n' "$AP_INTERFACE" "$AP_COUNTRY" > /etc/default/openastro-ap

cat > /etc/systemd/system/openastro-ap-iface.service <<'EOF'
[Unit]
Description=OpenAstro: create dedicated AP interface (ap0)
Before=NetworkManager.service
After=systemd-udev-trigger.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-ap-iface

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/openastro-ap-iface.conf <<'EOF'
[Unit]
After=openastro-ap-iface.service
Wants=openastro-ap-iface.service
EOF
systemctl enable openastro-ap-iface.service >/dev/null 2>&1

# autoconnect keeps the hotspot up from boot: the board is always reachable
# at ${AP_IP} via its own AP even when the user can't log in over their LAN.
AP_UUID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /etc/NetworkManager/system-connections
install -m 0600 /dev/null /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection
cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF
[connection]
id=OpenAstro-AP
uuid=${AP_UUID}
type=wifi
interface-name=ap0
autoconnect=true
# Prefer saved client networks on drivers that must share one interface.
autoconnect-priority=-10
# Retry forever: with the default (4 attempts) a slow first boot - vendor WiFi
# firmware or dnsmasq not ready yet - permanently blocks the AP until reboot.
autoconnect-retries=0

[wifi]
mode=ap
ssid=${AP_SSID}
band=${AP_BAND}
channel=${AP_CHANNEL}

[wifi-security]
key-mgmt=wpa-psk
psk=${AP_PASSPHRASE}

[ipv4]
method=shared
address1=${AP_IP}/24

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection

# Keyfile was just (re)written with the generic SSID - let the suffixer run
# again on next boot.
rm -f /var/lib/openastro/ssid-set

# The AP helper also sets the SSID, so it cannot race radio discovery.
systemctl disable openastro-ssid.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/openastro-ssid.service \
    /etc/systemd/system/NetworkManager.service.d/openastro-ssid.conf \
    /usr/local/sbin/openastro-ssid

# Regdom for the 5 GHz AP (hostapd used to set this via country_code; the NM
# path needs it set globally).
# Apply on the target at boot, never to the image-build host's radio.
cat > /etc/modprobe.d/openastro-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=${AP_COUNTRY}
EOF

# Retire the pre-NM hostapd/dnsmasq/iptables stack (no-ops on a fresh image;
# cleans up boards that ran the old layer).
systemctl disable --now hostapd dnsmasq openastro-ap-up.service >/dev/null 2>&1 || true
rm -f /etc/hostapd/hostapd.conf /etc/default/hostapd \
      /etc/dnsmasq.d/openastro-ap.conf /etc/openastro-nat.rules \
      /etc/sysctl.d/99-openastro-ap.conf \
      /etc/systemd/system/openastro-ap-up.service \
      /etc/NetworkManager/conf.d/10-openastro-wlan0-unmanaged.conf
systemctl daemon-reload >/dev/null 2>&1 || true

# WiFi behavior for an always-on hotspot: no powersave (an AP that naps
# drops clients serving a mount all night) and no scan MAC randomization
# (keeps the radio identity stable/predictable).
cat > /etc/NetworkManager/conf.d/20-openastro-wifi.conf <<'EOF'
[connection]
wifi.powersave=2

[device]
wifi.scan-rand-mac-address=no
EOF

systemctl enable NetworkManager >/dev/null 2>&1
systemctl enable ssh avahi-daemon bluetooth >/dev/null 2>&1

log "WiFi AP configured (SSID: ${AP_SSID}, band ${AP_BAND} ch${AP_CHANNEL}, ${AP_IP})."

# ============================================================
# First-boot reliability
# ============================================================
# The image build strips SSH host keys (unique per device). Regenerate them
# deterministically before sshd starts - otherwise ssh.service fails on first
# boot ("Connection refused" until a reboot), racing Armbian's first-run.
cat > /etc/systemd/system/openastro-sshkeys.service <<'EOF'
[Unit]
Description=OpenAstro: generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/openastro-after-keys.conf <<'EOF'
[Unit]
After=openastro-sshkeys.service
Wants=openastro-sshkeys.service
EOF
systemctl enable openastro-sshkeys.service >/dev/null 2>&1

# Persistent journal, so first-boot failures survive a power cycle and can
# actually be debugged (volatile journal cost us the evidence once).
install -d -m 2755 -g systemd-journal /var/log/journal

# ============================================================
# Astro-device permissions (present from first boot, so device
# access never depends on install order of AlpacaBridge)
# ============================================================
# ZWO EAF/EFW/CAA are USB HID devices; without this, /dev/hidraw* is
# root-only until AlpacaBridge's own udev rules land AND the device is
# replugged. Shipping the rule in the image removes that ordering trap.
cat > /etc/udev/rules.d/70-openastro-zwo-hid.rules <<'EOF'
# ZWO HID accessories (EAF focuser, EFW/EFWmini filter wheels, CAA rotator)
# Final assignments keep later vendor rules from making HID nodes world-writable.
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="03c3", GROUP:="plugdev", MODE:="0660"
KERNEL=="hiddev*", ATTRS{idVendor}=="03c3", GROUP:="plugdev", MODE:="0660"
EOF

# ============================================================
# System identity (turnkey - no Armbian first-boot wizard)
# ============================================================
log "Setting system identity..."
echo "$OA_HOSTNAME" > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1\t$OA_HOSTNAME/" /etc/hosts
else echo -e "127.0.1.1\t$OA_HOSTNAME" >> /etc/hosts; fi
id "$OA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,dialout,plugdev,audio,video "$OA_USER"
echo "${OA_USER}:${OA_PASS}" | chpasswd
# Disable Armbian's interactive first-login wizard (credentials are baked in).
systemctl disable armbian-firstlogin.service 2>/dev/null || true
rm -f /root/.not_logged_in_yet 2>/dev/null || true
# Remove factory root autologin normally retired by the skipped wizard.
for override in /etc/systemd/system/{getty@,getty@tty1,serial-getty@,serial-getty@ttyGS0}.service.d/override.conf; do
    if grep -Eq -- '--autologin[=[:space:]]+root([[:space:]]|$)' "$override" 2>/dev/null; then
        rm -f "$override"
    fi
done
systemctl daemon-reload >/dev/null 2>&1 || true

# ============================================================
# AlpacaBridge (preinstalled - the whole point of the appliance;
# a dark site has no internet to apt install from)
# ============================================================
# Install the repository's current ARM64 package. Set INSTALL_ALPACABRIDGE=no to skip.
INSTALL_ALPACABRIDGE="${INSTALL_ALPACABRIDGE:-yes}"
if [ "$INSTALL_ALPACABRIDGE" = yes ]; then
log "Installing AlpacaBridge from apt.openastro.net..."
curl -fsSL https://apt.openastro.net/repo/openastro-archive-keyring.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/openastro-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openastro-archive-keyring.gpg] https://apt.openastro.net trixie main" \
    > /etc/apt/sources.list.d/openastro.list
apt-get update -qq
apt-get install -y -qq alpacabridge >/dev/null
fi
if id alpacabridge >/dev/null 2>&1; then usermod -aG plugdev alpacabridge; fi

log "OpenAstro OS layer complete. Reboot after running directly on a board."
