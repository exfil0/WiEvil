#!/usr/bin/env bash
#
# hotspot_wizard.sh
#
# Automates creation of a "malicious hotspot" on Raspberry Pi OS (Debian Bookworm)
# using NetworkManager (for eth0), systemd-networkd (for wlan0 static IP),
# hostapd, dnsmasq, and iptables for optional NAT.
#
# Run as: sudo ./hotspot_wizard.sh
#

set -euo pipefail

## Helper function: print informational messages
function print_info() {
  echo -e "\n[INFO] $1\n"
}

## Helper: Must run as root
function check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Script must be run as root (sudo). Exiting."
    exit 1
  fi
}

## Prompt user for input with an optional default value
function prompt() {
  local var="$1"
  local prompt_msg="$2"
  local default_val="${3:-}"

  if [ -n "$default_val" ]; then
    read -r -p "$prompt_msg [$default_val]: " user_val
    if [ -z "$user_val" ]; then
      eval "$var=\"$default_val\""
    else
      eval "$var=\"$user_val\""
    fi
  else
    read -r -p "$prompt_msg: " user_val
    eval "$var=\"$user_val\""
  fi
}

check_root

print_info "Welcome to the Raspberry Pi Malicious Hotspot Wizard!

This script will:
 - Install 'hostapd', 'dnsmasq', and 'iptables'
 - Unmanage 'wlan0' from NetworkManager (leaving 'eth0' alone)
 - Use systemd-networkd to set 192.168.50.1 on 'wlan0'
 - Configure hostapd for a WPA2 AP
 - Configure dnsmasq for DHCP on 'wlan0'
 - Optionally enable NAT so AP clients have internet via 'eth0'

Proceed only on a fresh Raspberry Pi OS with NetworkManager managing eth0."

# Optional: Check OS is Debian Bookworm
if grep -q "bookworm" /etc/os-release; then
  print_info "OS release indicates Debian Bookworm. Good to proceed."
else
  echo "[WARNING] OS does not appear to be Debian Bookworm. Continuing anyway..."
fi

## Prompt user for AP settings
prompt AP_SSID "Enter AP SSID (hotspot name)" "MaliciousAP"
prompt AP_CHANNEL "Enter Wi-Fi channel (1,6,11, etc.)" "6"
prompt AP_COUNTRY "Enter 2-letter country code (US, ZA, etc.)" "US"
prompt AP_PSK "Enter WPA2 passphrase (8+ chars)" "TestPass123"

print_info "Using:
 - SSID: $AP_SSID
 - Channel: $AP_CHANNEL
 - Country: $AP_COUNTRY
 - Passphrase: $AP_PSK
"

## Step 2: Install packages
print_info "Installing hostapd, dnsmasq, and iptables..."
apt-get update
apt-get install -y hostapd dnsmasq iptables

## Step 3: Unmask and enable hostapd
print_info "Unmasking and enabling hostapd..."
systemctl unmask hostapd || true
systemctl enable hostapd

## Step 4: Unmanage wlan0 in NetworkManager
print_info "Configuring NetworkManager to ignore 'wlan0'..."
NM_CONF_DIR="/etc/NetworkManager/conf.d"
mkdir -p "$NM_CONF_DIR"
cat <<EOF > "$NM_CONF_DIR/10-unmanage-wlan0.conf"
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF

systemctl restart NetworkManager
print_info "NetworkManager restarted. Checking nmcli status:"
nmcli dev status || true

## Step 5: Configure systemd-networkd for static IP on wlan0
print_info "Setting 'wlan0' to 192.168.50.1 via systemd-networkd..."
mkdir -p /etc/systemd/network
cat <<EOF > /etc/systemd/network/30-wlan0.network
[Match]
Name=wlan0

[Network]
Address=192.168.50.1/24
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

# Bring wlan0 up manually if needed
ip link set wlan0 up || true

sleep 2
print_info "Current 'wlan0' IP info:"
ip addr show wlan0 | grep "inet " || true

## Step 6: Create /etc/hostapd/hostapd.conf
print_info "Creating minimal /etc/hostapd/hostapd.conf..."
cat <<EOF > /etc/hostapd/hostapd.conf
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
country_code=$AP_COUNTRY

wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=$AP_PSK
rsn_pairwise=CCMP
EOF

## Step 7: DAEMON_CONF in /etc/default/hostapd
print_info "Ensuring /etc/default/hostapd points to our config..."
if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

## Step 8: Start hostapd
print_info "Starting hostapd service..."
systemctl stop hostapd || true
systemctl start hostapd
sleep 2
systemctl status hostapd --no-pager || true

## Step 9: Configure dnsmasq for DHCP
print_info "Configuring dnsmasq for DHCP on 'wlan0'..."
if [ -f /etc/dnsmasq.conf ]; then
  mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig.$(date +%s)
fi

cat <<EOF > /etc/dnsmasq.conf
interface=wlan0
dhcp-range=192.168.50.50,192.168.50.100,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
EOF

systemctl enable dnsmasq
systemctl stop dnsmasq || true
systemctl start dnsmasq
sleep 2
systemctl status dnsmasq --no-pager || true

## Step 10: (Optional) NAT from wlan0 -> eth0
read -r -p "Enable NAT from wlan0 -> eth0 for internet? (y/N): " do_nat
if [[ "$do_nat" =~ ^[Yy]$ ]]; then
  print_info "Enabling NAT via iptables..."

  # 1) Turn on net.ipv4.ip_forward
  sed -i 's|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
  sysctl -p || true

  # 2) Add MASQUERADE rule
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

  # 3) Persist
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/iptables-rules.v4

  # If rc.local doesn't exist, create it
  if [ ! -f /etc/rc.local ]; then
    echo "#!/bin/sh -e" > /etc/rc.local
    echo "exit 0" >> /etc/rc.local
    chmod +x /etc/rc.local
  fi

  # Insert restore line if not present
  if ! grep -q "iptables-restore < /etc/iptables/iptables-rules.v4" /etc/rc.local; then
    sed -i '/^exit 0/i iptables-restore < /etc/iptables/iptables-rules.v4' /etc/rc.local
  fi

  print_info "NAT configuration complete. On reboot, iptables-restore will load from /etc/iptables/iptables-rules.v4."
else
  print_info "Skipping NAT. Clients will only have local network on wlan0, no internet forwarding."
fi

print_info "All done! Your malicious hotspot is now set up.

 - SSID: $AP_SSID
 - Pass: $AP_PSK
 - IP on wlan0: 192.168.50.1
 - DHCP range: 192.168.50.50 -> 192.168.50.100

Check logs:
  sudo journalctl -u hostapd -f
  sudo journalctl -u dnsmasq -f

A reboot is recommended to verify all services start automatically.
Enjoy your newly configured malicious hotspot (educational use only)!"
exit 0
