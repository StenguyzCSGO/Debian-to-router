#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

LAN_NET="192.168.50.0"
LAN_CIDR="192.168.50.0/24"
LAN_GW="192.168.50.1"
LAN_DHCP_START="192.168.50.50"
LAN_DHCP_END="192.168.50.150"
LAN_DNS="1.1.1.1,8.8.8.8"

cleanup() {
    warning "Cleaning up..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    if [ -n "${AP_IFACE:-}" ]; then
        nmcli dev set "$AP_IFACE" managed yes 2>/dev/null || true
        ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

log "Updating system packages..."
apt-get update -y
apt-get install -y hostapd dnsmasq iptables-persistent iw

log "Stopping existing services..."
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

systemctl unmask hostapd 2>/dev/null || true
systemctl unmask dnsmasq 2>/dev/null || true
systemctl unmask netfilter-persistent 2>/dev/null || true

log "Detecting network interfaces..."
mapfile -t available_wifi_interfaces < <(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" {print $1}')
mapfile -t source_eth_interfaces < <(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="ethernet" && $3=="connected" {print $1}')
supported_wifi_interfaces=()

for iface in "${available_wifi_interfaces[@]:-}"; do
    if [ -z "$iface" ]; then continue; fi
    
    phy="phy$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print $2}' || echo "")"
    if [ -n "$phy" ] && iw "$phy" info 2>/dev/null | grep -q 'AP$'; then
        supported_wifi_interfaces+=("$iface")
        log "Found AP-capable interface: $iface"
    fi
done

if [ "${#supported_wifi_interfaces[@]}" -eq 0 ]; then
    error "No Wi-Fi interface supporting AP mode found"
    exit 1
fi

if [ "${#source_eth_interfaces[@]}" -eq 0 ]; then
    error "No connected ethernet interface found for internet access"
    exit 1
fi

AP_IFACE="${supported_wifi_interfaces[0]}"
WAN_IFACE="${source_eth_interfaces[0]}"

log "Using Wi-Fi interface: $AP_IFACE"
log "Using WAN interface: $WAN_IFACE"

AP_name=""
while [ -z "$AP_name" ]
do
    read -p "Enter Access Point name (SSID): " AP_name

    if [ -z "$AP_name" ]; then
        error "SSID cannot be empty"
    fi
done

AP_password=""
while [ -z "$AP_password" ]
do
    read -s -p "Enter Access Point password: " AP_password

    if [ -z "$AP_password" ]; then
        error "Password cannot be empty"
    fi
done
echo

read -p "Access point start on boot (Y/N): " AP_reboot
echo


if [[ AP_reboot == "Y" ]]; then
    log "Access point start automatically on reboot"
    systemctl enable hostapd
    systemctl enable dnsmasq
    systemctl enable netfilter-persistent
fi

log "Configuring network interface..."
nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true
ip link set "$AP_IFACE" down 2>/dev/null || true
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "${LAN_GW}/24" dev "$AP_IFACE"
ip link set "$AP_IFACE" up

log "Enabling IP forwarding..."
cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null

log "Configuring hostapd..."
rm -f /etc/hostapd/hostapd.conf
mkdir -p /etc/hostapd
cat > /etc/hostapd/hostapd.conf <<EOF
interface=$AP_IFACE
driver=nl80211

ssid=$AP_name
hw_mode=g
channel=7

ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_passphrase=$AP_password
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ignore_broadcast_ssid=0
macaddr_acl=0
EOF

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

log "Configuring dnsmasq..."
rm -f /etc/dnsmasq.conf /etc/dnsmasq.d/router.conf
mkdir -p /etc/dnsmasq.d

cat > /etc/dnsmasq.conf <<EOF
conf-dir=/etc/dnsmasq.d
EOF

cat > /etc/dnsmasq.d/router.conf <<EOF
interface=$AP_IFACE
bind-interfaces

domain-needed
bogus-priv
no-resolv
server=1.1.1.1
server=8.8.8.8

dhcp-range=$LAN_DHCP_START,$LAN_DHCP_END,255.255.255.0,12h
dhcp-option=option:router,$LAN_GW
dhcp-option=option:dns-server,$LAN_GW

log-facility=/var/log/dnsmasq.log
log-dhcp

cache-size=1000
EOF

log "Configuring iptables..."
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X
iptables -t mangle -X

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
iptables -A FORWARD -i "$AP_IFACE" -o "$WAN_IFACE" -j ACCEPT
iptables -A FORWARD -i "$WAN_IFACE" -o "$AP_IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

netfilter-persistent save

rfkill unblock wifi

log "Starting services..."
if systemctl restart dnsmasq; then
    log "dnsmasq started successfully"
else
    error "Failed to start dnsmasq"
    systemctl status dnsmasq --no-pager
    exit 1
fi

if systemctl restart hostapd; then
    log "hostapd started successfully"
else
    error "Failed to start hostapd"
    systemctl status hostapd --no-pager
    exit 1
fi

sleep 3
if ! systemctl is-active --quiet hostapd; then
    error "hostapd is not running properly"
    log "Checking hostapd status..."
    systemctl status hostapd --no-pager
    journalctl -u hostapd --no-pager -n 20
    exit 1
fi

if ! systemctl is-active --quiet dnsmasq; then
    error "dnsmasq is not running properly"
    log "Checking dnsmasq status..."
    systemctl status dnsmasq --no-pager
    journalctl -u dnsmasq --no-pager -n 20
    exit 1
fi

trap - EXIT

log "Router configuration completed successfully!"
echo
echo "================================================"
echo "Access Point: $AP_name"
echo "Password: $AP_password"
echo "Interface: $AP_IFACE"
echo "Internet via: $WAN_IFACE"
echo "LAN Gateway: $LAN_GW"
echo "DHCP Range: $LAN_DHCP_START - $LAN_DHCP_END"
echo "DNS Servers: $LAN_DNS"
echo "================================================"
echo
log "Services are enabled for automatic startup"
log "You can check the status with:"
echo "  systemctl status hostapd dnsmasq"
echo "  journalctl -u hostapd -f"
echo "  journalctl -u dnsmasq -f"