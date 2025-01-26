# WiEvil + Alfa AC1900 Integration Wizard

**WiEvilWithAlfa.sh** is a **“mega-wizard”** script that seamlessly combines:

1. **ALFA AC1900** (RTL8814AU) **driver installation** via [morrownr/8814au](https://github.com/morrownr/8814au)
2. Options to put the ALFA adapter in **monitor mode** (packet injection/sniffing) **or** use it for a **malicious AP**.
3. **Root CA** generation + **captive portal** for HTTPS interception.
4. **Optional** NAT and **mitmproxy** for silent decryption of trusted clients.

> **Disclaimer**: Strictly for **educational** or **authorized** lab usage. Creating a malicious AP and intercepting traffic is **illegal** without explicit permission.

---

## Features

- **Alfa AC1900 driver**: Automatically clones & installs the **morrownr** fork, using DKMS if possible.
- **Monitor mode** or **AP mode**: The script offers a prompt. If you pick monitor mode, it sets `wlan1` to monitor and exits. If AP mode, it integrates with the malicious AP.
- **Root CA** + captive portal**: Just like original WiEvil, a minimal `index.html` on `192.168.50.1`, instructing victims to install `ca.crt`.
- **NAT** (optional) if you want real internet on the AP.
- **mitmproxy** (optional) for fully transparent HTTPS MITM (once users trust the CA).

---

## Requirements

- **Raspberry Pi OS (Debian Bookworm)** or similar, using **NetworkManager** for `eth0`.
- **systemd-networkd** for `wlanX`.
- `sudo` privileges.
- A stable or minimal config (avoid conflicting hostapd/dhcpcd setups).

---

## Usage

1. **Clone** or **download** this script (e.g., `WiEvilWithAlfa.sh`).

2. **Make it executable**:
   ```bash
   chmod +x WiEvilWithAlfa.sh
   ```

3. **Run** with sudo:
   ```bash
   sudo ./WiEvilWithAlfa.sh
   ```

4. **Answer** prompts:
   - Install ALFA driver? (y/N)
   - Use ALFA for monitor mode, malicious AP, or skip?
   - SSID, WPA2 pass, NAT, and mitmproxy choices.

5. **Reboot** recommended:
   ```bash
   sudo reboot
   ```

---

## After Installation

- If **monitor mode** was chosen: The script puts `wlan1` in monitor, you can use `aircrack-ng` or other tools.
- If **AP mode**: The script sets up `hostapd` + `dnsmasq` on `wlan1` (or `wlan0` if skip ALFA). The Pi IP is `192.168.50.1/24`. All traffic gets captive-redirected to an `index.html` served by Apache.
- If **NAT** is on, clients can eventually reach the internet. If **mitmproxy** is installed, port 443 is redirected to `8081`, letting you run `mitmproxy --mode transparent -p 8081` for full SSL intercept.

---

## Troubleshooting

- **Driver Build Errors**: Possibly a kernel mismatch. Check logs in `/var/lib/dkms/rtl8814au/`.
- **No AP**: Confirm `hostapd` references the right interface, `wlan1`, etc. Check `systemctl status hostapd`.
- **No internet**: If NAT is off, that’s expected. If NAT is on, confirm Pi can ping external addresses.
- **User not installing CA**: They must do so manually on their device.

---

## Uninstalling / Resetting

1. **dkms remove** the 8814au driver if you no longer need it.
2. **Stop hostapd/dnsmasq**:
   ```bash
   sudo systemctl stop hostapd dnsmasq
   sudo systemctl disable hostapd dnsmasq
   ```
3. **Flush** iptables or remove references in `/etc/rc.local`.
4. Remove `/etc/evilca/`, `/var/www/html/ca.crt`, etc.

---

## License

Provided **as is** for **educational** demonstration. Use responsibly.
