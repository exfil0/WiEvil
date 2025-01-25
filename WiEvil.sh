#!/usr/bin/env bash
#
# WiEvil.sh - Enhanced malicious hotspot wizard for Raspberry Pi OS (Debian Bookworm)
# 
# This script automates:
#   - Checking for conflicting services (like dhcpcd)
#   - Ensuring eth0 has internet (via NetworkManager)
#   - Setting up systemd-networkd for wlan0 => 192.168.50.1
#   - Installing and configuring hostapd + dnsmasq
#   - (Optional) iptables NAT from wlan0 -> eth0
#   - Performing final checks
#
# Usage: sudo ./WiEvil.sh

set -euo pipefail

# Helper: print info
function print_info() {
  echo -e "\n[INFO] $1\n"
}

# Helper: must be root
function check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root (sudo). Exiting."
    exit 1
  fi
}

# Helper: prompt
function prompt() {
  local varname="$1"
  local message="$2"
  local default_val="${3:-}"

  if [ -n "$default_val" ]; then
    read -r -p "$message [$default_val]: " user_val
    if [ -z "$user_val" ]; then
      eval "$varname=\"$default_val\""
    else
      eval "$varname=\"$user_val\""
    fi
  else
    read -r -p "$message: " user_val
    eval "$varname=\"$user_val\""
  fi
}

check_root

print_info "Welcome to the Enhanced Raspberry Pi Malicious Hotspot Wizard!

This script will:
 - Stop conflicting services (like dhcpcd) if found
 - Verify Pi's internet on eth0 (managed by NetworkManager)
 - Configure systemd-networkd on wlan0 for 192.168.50.1
 - Install & configure hostapd, dnsmasq, iptables for NAT
 - Perform final checks
Use on Debian Bookworm + NetworkManager. 
Proceed only on a fresh Pi OS environment.
"

# --- 1) Check OS version (optional) ---
if grep -q "bookworm" /etc/os-release; then
  print_info "OS: Debian Bookworm confirmed."
else
  echo "[WARNING] OS doesn't appear to be Bookworm. Continuing anyway..."
fi

# --- 2) Detect & possibly stop dhcpcd if installed ---
DHCP_SERVICE="dhcpcd.service"
dhcpcd_path="$(command -v dhcpcd || true)"

if [ -n "$dhcpcd_path" ] || systemctl status "$DHCP_SERVICE" >/dev/null 2>&1; then
  print_info "dhcpcd is installed or running. This can conflict with our setup."
  read -r -p "Stop & disable dhcpcd now? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl stop dhcpcd.service || true
    systemctl disable dhcpcd.service || true
    echo "[INFO] dhcpcd stopped & disabled."
  else
    echo "[WARNING] Keeping dhcpcd might cause conflicts. You have been warned."
  fi
fi

# --- 3) Check Pi's internet connectivity on eth0 ---
print_info "Verifying internet on eth0 (via NetworkManager)..."
# A quick ping test
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
  print_info "Internet is reachable. Good."
else
  echo "[WARNING] Pi can't ping 8.8.8.8. Internet might not be set up. 
We can continue, but NAT won't help clients get out if Pi has no internet."
  read -r -p "Continue anyway? (y/N): " cont
  if [[ ! "$cont" =~ ^[Yy]$ ]]; then
    echo "[INFO] Exiting."
    exit 0
  fi
fi

# --- 4) Prompt for AP settings ---
prompt AP_SSID "Enter AP SSID" "MaliciousAP"
prompt AP_CHANNEL "Enter Wi-Fi channel (1,6,11,...)" "6"
prompt AP_COUNTRY "Enter 2-letter country code" "US"
prompt AP_PSK "Enter WPA2 passphrase (≥8 chars)" "TestPass123"

print_info "Using:
  SSID: $AP_SSID
  Channel: $AP_CHANNEL
  Country: $AP_COUNTRY
  Passphrase: $AP_PSK
"

# --- 5) Install packages ---
print_info "Installing hostapd, dnsmasq, iptables..."
apt-get update
apt-get install -y hostapd dnsmasq iptables

# Unmask & enable hostapd
print_info "Unmasking hostapd..."
systemctl unmask hostapd || true
systemctl enable hostapd

# --- 6) Unmanage wlan0 in NetworkManager ---
print_info "Configuring NetworkManager to ignore wlan0..."
NM_CONF="/etc/NetworkManager/conf.d/10-unmanage-wlan0.conf"
mkdir -p /etc/NetworkManager/conf.d
cat <<EOF > "$NM_CONF"
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
systemctl restart NetworkManager
nmcli dev status || true

# --- 7) systemd-networkd for wlan0 => 192.168.50.1 ---
print_info "Setting up systemd-networkd for wlan0 => 192.168.50.1..."
mkdir -p /etc/systemd/network
cat <<EOF > /etc/systemd/network/30-wlan0.network
[Match]
Name=wlan0

[Network]
Address=192.168.50.1/24
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

ip link set wlan0 up || true
sleep 2
ip addr show wlan0 | grep "inet " || echo "[WARNING] wlan0 may still appear DOWN until hostapd starts."

# --- 8) hostapd config ---
print_info "Creating /etc/hostapd/hostapd.conf..."
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

# Make sure /etc/default/hostapd has DAEMON_CONF
if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

print_info "Starting hostapd..."
systemctl stop hostapd || true
systemctl start hostapd
sleep 2
systemctl status hostapd --no-pager || true

# --- 9) dnsmasq for DHCP on wlan0 ---
print_info "Configuring dnsmasq for DHCP..."
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
systemctl restart dnsmasq
systemctl status dnsmasq --no-pager || true

# --- 10) Optional NAT ---
read -r -p "Enable NAT from wlan0 -> eth0 for internet? (y/N): " do_nat
if [[ "$do_nat" =~ ^[Yy]$ ]]; then
  print_info "Enabling NAT..."

  # enable ip_forward
  sed -i 's|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
  sysctl -p || true

  # Add MASQUERADE
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

  # persist
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/iptables-rules.v4

  # add to /etc/rc.local if not present
  if [ ! -f /etc/rc.local ]; then
    echo "#!/bin/sh -e" > /etc/rc.local
    echo "exit 0" >> /etc/rc.local
    chmod +x /etc/rc.local
  fi

  if ! grep -q "iptables-restore < /etc/iptables/iptables-rules.v4" /etc/rc.local; then
    sed -i '/^exit 0/i iptables-restore < /etc/iptables/iptables-rules.v4' /etc/rc.local
  fi

  # Quick NAT test: We already know Pi can ping 8.8.8.8, so let's see if iptables is in place
  print_info "NAT is set. Try client test next."

else
  print_info "Skipping NAT. Devices on wlan0 are local-only."
fi

# --- 11) Final checks
print_info "Final Checks:
1) 'hostapd' should be running. 
2) 'dnsmasq' should be running.
3) 'ip addr show wlan0' should show 192.168.50.1
4) If NAT is enabled, Pi can reach the internet, and so can AP clients.

Connect a phone/laptop to '$AP_SSID' (pass: '$AP_PSK'), 
Check if it gets an IP in 192.168.50.x, 
Then test internet (if NAT is on).

A reboot is recommended:
  sudo reboot
"

exit 0
