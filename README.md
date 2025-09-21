# Debian-to-router

Turn an old PC or Raspberry Pi into a Wi‑Fi router and access point. This script configures hostapd (AP), dnsmasq (DHCP/DNS), and iptables (NAT) to share your wired internet over Wi‑Fi — a cheap alternative to buying a new router.

## What it does
- Detects a Wi‑Fi adapter that supports AP mode and a connected Ethernet interface for internet (WAN).
- Configures the Wi‑Fi interface as a LAN gateway: 192.168.50.1/24.
- Starts a WPA2 Wi‑Fi network (your SSID and password).
- Serves DHCP and DNS to clients via dnsmasq.
- Enables NAT and IPv4 forwarding to share internet from WAN to Wi‑Fi.
- Lets you choose if the router setup is temporary (this boot only) or persistent (after every reboot).

## Prerequisites
- Debian/Ubuntu/Raspberry Pi OS with systemd.
- Root privileges (sudo).
- A working wired Ethernet connection with internet access.
- A free Wi‑Fi adapter that supports AP mode (nl80211). You can check support with:
  - iw list | grep -A5 "Supported interface modes" (look for AP)
- NetworkManager installed (script uses nmcli to detect/manage interfaces).

## Quick start
```bash
# 1) Get the code
git clone https://github.com/yourname/Debian-to-router.git
cd Debian-to-router

# 2) Make the script executable
chmod +x router.sh

# 3) Run as root
sudo ./router.sh
```

During the run you will be prompted to:
- Enter the Wi‑Fi network name (SSID).
- Enter a password (minimum 8 characters).
- Choose whether to enable router mode after every reboot (persistent) or only for this session.

Connect your devices to the new Wi‑Fi network when it’s up.

## Defaults and customization
Edit the variables at the top of router.sh before running if needed:
- LAN: 192.168.50.0/24, gateway 192.168.50.1
- DHCP range: 192.168.50.50 – 192.168.50.150
- Upstream DNS: 1.1.1.1, 8.8.8.8 (clients are handed the router as DNS; dnsmasq forwards upstream)
- Wi‑Fi: 2.4 GHz, channel 7, WPA2-PSK

To change Wi‑Fi channel or other radio settings later, edit /etc/hostapd/hostapd.conf.

## Persistence modes
- Non‑persistent (recommended for quick tests)
  - Changes apply for this boot only. Reboot to revert.
- Persistent (start at every reboot)
  - Enables and configures: hostapd, dnsmasq, netfilter-persistent
  - Marks the AP interface unmanaged in NetworkManager
  - Creates /etc/network/interfaces.d/<iface>.conf for static IP
  - Enables IPv4 forwarding via sysctl

## Files and services this script touches
- Services: hostapd, dnsmasq, netfilter-persistent
- Config:
  - /etc/hostapd/hostapd.conf
  - /etc/default/hostapd
  - /etc/dnsmasq.conf and /etc/dnsmasq.d/router.conf
  - /etc/sysctl.d/99-router-ipforward.conf (IPv4 forwarding)
  - /etc/NetworkManager/conf.d/unmanaged-<iface>.conf (if persistent)
  - /etc/network/interfaces.d/<iface>.conf (if persistent)
- Firewall/NAT: iptables rules saved via netfilter-persistent

## Troubleshooting
- Check service status and logs:
  - systemctl status hostapd dnsmasq
  - journalctl -u hostapd -f
  - journalctl -u dnsmasq -f
- Verify your Wi‑Fi adapter supports AP mode (iw list).
- Ensure rfkill is not blocking Wi‑Fi (the script runs rfkill unblock wifi).
- If NetworkManager manages the AP interface, disable management or use persistent mode to make it unmanaged.  

## Notes
- Use a strong Wi‑Fi password.
- Variables of the AP aren't asked to the user to prevent errors (But you can change them if you are experimented).
- Regulatory domain and optimal channel selection are not auto‑tuned; adjust hostapd.conf for your country/channel as needed.
- This script assumes NetworkManager is present; on minimal servers without it, detection may fail.
