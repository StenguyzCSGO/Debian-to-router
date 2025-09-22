# Debian to Router

Transform a Debian PC or Raspberry Pi into a fully functional Wi-Fi router with DHCP, DNS, and NAT capabilities.

## Features

- **Automatic interface detection**: Finds Wi-Fi adapters supporting AP mode and connected Ethernet interfaces
- **Complete router functionality**: Hostapd (access point), dnsmasq (DHCP/DNS), iptables (NAT/forwarding)
- **Persistent or temporary mode**: Choose between one-time setup or automatic startup on boot
- **Systemd service integration**: Single service manages all components in correct order
- **Resource optimization**: Optional TTY-only mode to disable GUI and save resources
- **Easy cleanup**: Remove all configurations and restore original state

## Requirements

- Debian/Ubuntu/Raspberry Pi OS (systemd-based)
- Root privileges
- Ethernet connection with internet access (WAN)
- Wi-Fi adapter supporting AP mode (nl80211 driver)
- NetworkManager installed

### Check Wi-Fi AP support

```bash
iw list | grep -A 10 "Supported interface modes"
# Look for "AP" in the output
```

## Installation

```bash
# Clone repository
git clone https://github.com/StenguyzCSGO/Debian-to-router.git
cd Debian-to-router

# Make executable
chmod +x router.sh

# Run as root
sudo ./router.sh
```

## Usage

### Interactive Setup

The script will prompt you for:

1. **Wi-Fi network name (SSID)**: Your access point name
2. **Password**: Minimum 8 characters, WPA2-PSK encryption
3. **Persistent mode**: Enable automatic startup on boot
4. **TTY mode** (if persistent): Disable graphical interface to save resources

### Post-Installation

After successful setup, the script is installed as:

```bash
sudo router-mode
```

Monitor services:

```bash
systemctl status router-mode.service
systemctl status hostapd dnsmasq
journalctl -u router-mode -f
```

### Remove Configuration

```bash
sudo router-mode
# Answer 'y' to cleanup prompt
```

This removes all configurations, restores NetworkManager control, resets iptables, and re-enables GUI if disabled.

## Default Configuration

| Setting | Value |
|---------|-------|
| LAN Gateway | 192.168.50.1 |
| LAN Subnet | 192.168.50.0/24 |
| DHCP Range | 192.168.50.50 - 192.168.50.150 |
| DNS Servers | 1.1.1.1, 8.8.8.8 |
| Wi-Fi Channel | 7 (2.4 GHz) |
| Encryption | WPA2-PSK |

## How It Works

### Persistent Mode (Systemd Service)

1. Script copies itself to `/usr/local/sbin/router-mode`
2. Creates `router-mode.service` systemd unit
3. Service starts after network and NetworkManager
4. Configuration saved to `/etc/router-mode/config`
5. On boot: loads config, detects interfaces, starts hostapd/dnsmasq

### Network Configuration

- Wi-Fi interface configured with static IP (192.168.50.1/24)
- NetworkManager releases control of Wi-Fi interface
- IPv4 forwarding enabled via sysctl
- NAT configured with iptables MASQUERADE
- Hostapd creates WPA2 access point
- Dnsmasq provides DHCP and DNS forwarding

## File Locations

```
/usr/local/sbin/router-mode              # Installed script
/etc/router-mode/config                  # Saved configuration
/etc/systemd/system/router-mode.service  # Systemd service
/etc/hostapd/hostapd.conf                # Access point config
/etc/dnsmasq.d/router.conf               # DHCP/DNS config
/etc/NetworkManager/conf.d/ROUTER_MODE.conf
/etc/network/interfaces.d/ROUTER_MODE.conf
/etc/sysctl.d/99-router-ipforward.conf
```

## TTY Mode (Console Only)

When enabled, the system boots to text console (TTY) instead of graphical interface:

**Switch between TTY consoles:**
- `Ctrl+Alt+F1` to `F6`: Access TTY1-6
- `Alt+F1` to `F6`: Switch TTY (when already in console)

**Temporarily start GUI:**
```bash
sudo systemctl start gdm3  # or lightdm/sddm
```

**Permanently re-enable GUI:**
```bash
sudo systemctl set-default graphical.target
sudo reboot
```

## Troubleshooting

**Service won't start:**
```bash
journalctl -u router-mode -n 50
systemctl status hostapd --no-pager
```

**Wi-Fi adapter not detected:**
```bash
iw list  # Check AP mode support
nmcli device  # Verify interface detection
```

**No internet on connected devices:**
```bash
# Check NAT rules
sudo iptables -t nat -L -n -v

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Verify WAN interface has internet
ping -I eth0 8.8.8.8
```

**Interface blocked:**
```bash
rfkill list
rfkill unblock wifi
```

## Security Notes

- Use strong WPA2 passwords (minimum 8 characters)
- Configuration file `/etc/router-mode/config` is chmod 600 (root only)
- Consider firewall rules for production deployments
- Default configuration accepts all forwarded traffic (adjust iptables for restrictions)

## Advanced Configuration

Edit `/etc/hostapd/hostapd.conf` for:
- Channel selection (`channel=7`)
- Wi-Fi band (`hw_mode=g` for 2.4GHz, `hw_mode=a` for 5GHz)
- Country code (`country_code=US`)
- Hidden SSID (`ignore_broadcast_ssid=1`)

Edit `/etc/dnsmasq.d/router.conf` for:
- DHCP lease time (`12h`)
- DNS servers (`server=1.1.1.1`)
- Static IP assignments
- Custom domain name

Restart services after changes:
```bash
sudo systemctl restart router-mode.service
```

## License

MIT License - See LICENSE file for details

## Contributing

Pull requests welcome. For major changes, please open an issue first.
