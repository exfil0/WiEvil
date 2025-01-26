# WiEvil.sh

![WiEvil Interception Demo](https://github.com/exfil0/WiEvil/blob/main/demo-WiEvil-Interception.png)

**WiEvil.sh** is a comprehensive Bash script for setting up a malicious Wi-Fi hotspot on **Raspberry Pi OS (Debian Bookworm)**. It generates a **Root CA** to facilitate **certificate-based** HTTPS interception, serves that certificate via a **captive portal**, and optionally installs **mitmproxy** for full HTTPS MITM.

> **Disclaimer**: This project is for **educational / authorized** security testing only. Creating a rogue AP and intercepting traffic is **illegal** without explicit permission.

---

## Features

1. **NetworkManager + systemd-networkd**: Leaves `eth0` to NetworkManager, `wlan0` to systemd-networkd.
2. **Root CA Generation**: Creates a self-signed CA (`/etc/evilca/`) and places the `.crt` file in `/var/www/html/ca.crt`.
3. **Captive Portal**: Uses **Apache** to serve a minimal `index.html` that instructs users to install the CA.
4. **Rogue AP**: Sets up **hostapd** + **dnsmasq** to broadcast an SSID (e.g., `MaliciousAP`) on `192.168.50.1/24`.
5. **iptables** Redirection:
   - Defaults to sending all HTTP/HTTPS to the captive portal.
   - (Optional) NAT from `wlan0` → `eth0`, so devices can reach the internet once captive rules are removed or bypassed.
   - (Optional) Install & configure **mitmproxy** to silently decrypt all HTTPS.

---

## Requirements

- **Raspberry Pi OS (Debian Bookworm)**
- **NetworkManager** controlling `eth0`
- **systemd-networkd** for `wlan0`
- `sudo` privileges
- Minimal environment to avoid conflicts

---

## Usage

1. **Clone** the repository:

   ```bash
   git clone https://github.com/exfil0/WiEvil.git
   cd WiEvil
   ```
2. **Make the script executable**:

   ```bash
   chmod +x WiEvil.sh
   ```
3. **Run** with sudo:

   ```bash
   sudo ./WiEvil.sh
   ```
4. **Answer** the prompts:
   - SSID, channel, country code, passphrase.
   - CA name.
   - Whether to enable NAT.
   - Whether to install **mitmproxy**.
5. **Reboot** recommended:

   ```bash
   sudo reboot
   ```

---

## After Installation

1. **Rogue AP**: A device sees your chosen SSID. Connect with the provided WPA2 pass.
2. **Captive Portal**: By default, all traffic on ports 80/443 is redirected to `192.168.50.1:80`, showing a page instructing them to install your CA.
3. **Root CA**: In `/etc/evilca/`, also served at `http://192.168.50.1/ca.crt`.
4. If **NAT** is enabled, devices can get real internet once they remove or modify the captive portal rules.

---

## Using mitmproxy

If you choose to install **mitmproxy**, the script automatically removes the `443->80` captive rule and adds `443->8081` so you can run:

```bash
sudo mitmproxy --mode transparent -p 8081
```

**Navigation** in mitmproxy:
- **Up/Down**: select flows
- **Enter**: inspect the selected flow
- **Left/Right** or **Tab**: switch between request & response
- **q** or **Esc**: go back
- **Shift+Q**: quit mitmproxy
- **?**: help screen

Once the client trusts your CA, HTTPS traffic is decrypted & re-encrypted.

---

## Removing/Bypassing the Captive Portal

1. Flush or delete iptables rules:

   ```bash
   sudo iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination 192.168.50.1:80
   sudo iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 443 -j DNAT --to-destination 192.168.50.1:80
   ```
2. Re-save if needed:

   ```bash
   iptables-save > /etc/iptables/iptables-rules.v4
   ```

---

## Troubleshooting

- **No IP**: Check `dnsmasq` status, ensure `wlan0` is `192.168.50.1`.
- **No captive page**: Verify iptables rules with `iptables -t nat -L --line-numbers`.
- **No internet**: If NAT is disabled, that’s expected. If NAT is on, confirm Pi can ping external sites.
- **User won’t install CA**: They must do so manually—no forced method.

---

## Uninstalling / Resetting

1. **Flush** iptables or remove custom rules from `/etc/rc.local`.
2. **Enable** or rename `/etc/NetworkManager/conf.d/10-unmanage-wlan0.conf` if you want NM to re-manage `wlan0`.
3. Stop & disable hostapd/dnsmasq:
   ```bash
   sudo systemctl stop hostapd dnsmasq
   sudo systemctl disable hostapd dnsmasq
   ```
4. Remove your CA from `/etc/evilca` and `/var/www/html/ca.crt`.

---

## License

This code is offered **as is**, for **educational** or **authorized** lab usage. No formal license. Use responsibly.

### Additional Note
You can integrate **mitmproxy** seamlessly by redirecting port 443 to its listening port. Once the user installs `ca.crt`, all HTTPS traffic can be transparently intercepted.

---

## Roadmap with Progress Bars

Below is the **WiEvil** folder structure, plus progress indicators:

```bash
WiEvil/
├── README.md [100%]
├── WiEvil.sh [100%]
├── Integrations/ [70%]
│   ├── WiEvilWithAlfa.sh [80%]
│   ├── EvilTwinMode/
│   │   ├── run-evil-twin.sh [In Progress - 50%]
│   │   ├── deauth-helper.sh [Planned - 0%]
│   │   └── README.md [Planned - 0%]
│   ├── MonitorMode/
│   │   ├── set-monitor.sh [Complete - 100%]
│   │   └── README.md [Planned - 0%]
│   └── Bettercap/
│       ├── run-bettercap.sh [Planned - 0%]
│       ├── bettercap-config.yml [Planned - 0%]
│       └── README.md [Planned - 0%]
├── Themes/ [60%]
│   ├── coffee-shop/
│   │   ├── index.html [Complete]
│   │   ├── style.css [Complete]
│   │   └── README.md [Planned]
│   ├── airport/
│   │   ├── index.html [In Progress]
│   │   └── style.css [In Progress]
│   └── branding-template.md [Planned]
├── Tools/ [50%]
│   ├── InstallAlfaAC1900.sh [Complete]
│   ├── captive-bypass-scripts/
│   │   ├── ... [Planned]
│   └── README.md [Planned]
└── docs/ [40%]
    ├── advanced-scenarios.md [In Progress]
    ├── captive-portal-bypass.md [Planned]
    └── images/
        ├── demo-WiEvil-Interception.png [Complete]
        └── ...
```
