#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONF_NAME_FILE="ROUTER_MODE"
CONFIG_FILE="/etc/router-mode/config"
CONFIG_DIR="/etc/router-mode"
SCRIPT_INSTALL_PATH="/usr/local/sbin/router-mode"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Router mode configuration
AP_IFACE="$AP_IFACE"
WAN_IFACE="$WAN_IFACE"
AP_NAME="$AP_NAME"
AP_PASSWORD="$AP_PASSWORD"
LAN_GW="$LAN_GW"
LAN_DHCP_START="$LAN_DHCP_START"
LAN_DHCP_END="$LAN_DHCP_END"
LAN_DNS="$LAN_DNS"
EOF
    chmod 600 "$CONFIG_FILE"
}

cleanup_router() {
    log "Stop and disable at boot services for the AP..."
    systemctl disable --quiet router-mode.service 2>/dev/null || true
    systemctl stop --quiet router-mode.service 2>/dev/null || true
    systemctl disable --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true
    systemctl stop --quiet hostapd dnsmasq netfilter-persistent 2>/dev/null || true

    log "Return control of the interface to NetworkManager..."
    if [ -f /etc/network/interfaces.d/ROUTER_MODE.conf ]; then
        AP_IFACE_CLEAN=$(awk '/iface/ {print $2}' /etc/network/interfaces.d/ROUTER_MODE.conf)
        if [ -n "$AP_IFACE_CLEAN" ]; then
            nmcli dev set "$AP_IFACE_CLEAN" managed yes 2>/dev/null || true
            ip addr flush dev "$AP_IFACE_CLEAN" 2>/dev/null || true
        fi
    fi

    log "Deleting conf file and restore default ones..."
    rm -f /etc/network/interfaces.d/${CONF_NAME_FILE}.conf
    rm -f /etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf
    rm -f /etc/hostapd/hostapd.conf
    rm -f /etc/dnsmasq.d/router.conf
    rm -f /etc/dnsmasq.conf
    rm -f /etc/sysctl.d/99-router-ipforward.conf
    rm -rf "$CONFIG_DIR"
    rm -f "$SCRIPT_INSTALL_PATH"
    [ -f /etc/hostapd/default_hostapd.conf ] && mv /etc/hostapd/default_hostapd.conf /etc/hostapd/hostapd.conf
    [ -f /etc/default_dnsmasq.conf ] && mv /etc/default_dnsmasq.conf /etc/dnsmasq.conf
    [ -f /etc/old_sysctl.conf ] && mv /etc/old_sysctl.conf /etc/sysctl.conf

    log "Resetting iptables rules..."
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
    iptables -t nat -X
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    sysctl --system >/dev/null

    netfilter-persistent save || true

    log "Restarting NetworkManager..."
    systemctl restart NetworkManager || true
    
    enable_graphical_interface
}

detect_interfaces() {
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
        return 1
    fi

    if [ "${#source_eth_interfaces[@]}" -eq 0 ]; then
        error "No connected ethernet interface found for internet access"
        return 1
    fi

    AP_IFACE="${supported_wifi_interfaces[0]}"
    WAN_IFACE="${source_eth_interfaces[0]}"

    log "Using Wi-Fi interface: $AP_IFACE"
    log "Using WAN interface: $WAN_IFACE"
    return 0
}

install_packages() {
    log "Updating system packages..."
    apt-get update -y
    apt-get install -y hostapd dnsmasq iptables-persistent iw
}

stop_services() {
    log "Stopping existing services..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true

    systemctl unmask hostapd 2>/dev/null || true
    systemctl unmask dnsmasq 2>/dev/null || true
    systemctl unmask netfilter-persistent 2>/dev/null || true
}

configure_network_interface() {
    log "Configuring network interface..."
    nmcli dev set "$AP_IFACE" managed no 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip addr add "${LAN_GW}/24" dev "$AP_IFACE"
    ip link set "$AP_IFACE" up
}

enable_ip_forwarding() {
    log "Enabling IP forwarding..."
    [ -f /etc/sysctl.conf ] && [ ! -f /etc/old_sysctl.conf ] && mv /etc/sysctl.conf /etc/old_sysctl.conf
    cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF
    mkdir -p /etc/sysctl.d/
    cat > /etc/sysctl.d/99-router-ipforward.conf <<EOF
net.ipv4.ip_forward=1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl --system >/dev/null
}

configure_hostapd() {
    log "Configuring hostapd..."
    [ -f /etc/hostapd/hostapd.conf ] && [ ! -f /etc/hostapd/default_hostapd.conf ] && \
        mv /etc/hostapd/hostapd.conf /etc/hostapd/default_hostapd.conf
    
    cat > /etc/hostapd/hostapd.conf <<EOF
# Router mode conf
interface=$AP_IFACE
driver=nl80211

ssid=$AP_NAME
hw_mode=g
channel=7

ieee80211n=1
wmm_enabled=1

auth_algs=1
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

ignore_broadcast_ssid=0
macaddr_acl=0
EOF

    cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
}

configure_dnsmasq() {
    log "Configuring dnsmasq..."
    [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/default_dnsmasq.conf ] && \
        mv /etc/dnsmasq.conf /etc/default_dnsmasq.conf
    
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

cache-size=10000
EOF
}

configure_iptables() {
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
}

configure_persistent() {
    log "Configuring persistent router functionality..."
    
    log "Prevent NetworkManager from managing the interface"
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/${CONF_NAME_FILE}.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IFACE}
EOF
    systemctl reload NetworkManager || true
    
    log "Creating persistent network configuration..."
    mkdir -p /etc/network/interfaces.d/
    cat > /etc/network/interfaces.d/${CONF_NAME_FILE}.conf <<EOF
auto ${AP_IFACE}
iface ${AP_IFACE} inet static
    address ${LAN_GW}
    netmask 255.255.255.0
EOF
}

install_script() {
    log "Installing script to system location..."
    
    cp "$0" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    
    log "Script installed to $SCRIPT_INSTALL_PATH"
}

start_services() {
    rfkill unblock wifi || true

    log "Starting services..."
    if systemctl restart dnsmasq; then
        log "dnsmasq started successfully"
    else
        error "Failed to start dnsmasq"
        systemctl status dnsmasq --no-pager
        return 1
    fi

    if systemctl restart hostapd; then
        log "hostapd started successfully"
    else
        error "Failed to start hostapd"
        systemctl status hostapd --no-pager
        return 1
    fi

    sleep 3
    if ! systemctl is-active --quiet hostapd; then
        error "hostapd is not running properly"
        log "Checking hostapd status..."
        systemctl status hostapd --no-pager
        journalctl -u hostapd --no-pager -n 20
        return 1
    fi

    if ! systemctl is-active --quiet dnsmasq; then
        error "dnsmasq is not running properly"
        log "Checking dnsmasq status..."
        systemctl status dnsmasq --no-pager
        journalctl -u dnsmasq --no-pager -n 20
        return 1
    fi

    return 0
}

create_systemd_service() {
    log "Creating systemd service..."
    cat > /etc/systemd/system/router-mode.service <<EOF
[Unit]
Description=Router Mode Service
After=network.target NetworkManager.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_INSTALL_PATH --service
ExecStop=$SCRIPT_INSTALL_PATH --service-stop
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable router-mode.service
    log "Systemd service created and enabled"
}

apply_router_config() {
    if ! detect_interfaces; then
        return 1
    fi
    
    configure_network_interface
    enable_ip_forwarding
    configure_hostapd
    configure_dnsmasq
    configure_iptables
    
    if ! start_services; then
        return 1
    fi
    
    return 0
}

service_mode_start() {
    log "Router mode service starting..."
    
    if ! load_config; then
        error "No configuration found. Run script interactively first."
        exit 1
    fi
    
    LAN_GW="${LAN_GW:-192.168.50.1}"
    LAN_DHCP_START="${LAN_DHCP_START:-192.168.50.50}"
    LAN_DHCP_END="${LAN_DHCP_END:-192.168.50.150}"
    LAN_DNS="${LAN_DNS:-1.1.1.1,8.8.8.8}"
    
    if apply_router_config; then
        log "Router mode service started successfully"
        exit 0
    else
        error "Failed to start router mode service"
        exit 1
    fi
}

service_mode_stop() {
    log "Router mode service stopping..."
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    log "Router mode service stopped"
}

disable_graphical_interface() {
    log "Disabling graphical interface for lower resource usage..."
    
    if systemctl is-active --quiet gdm3 || \
       systemctl is-active --quiet lightdm || \
       systemctl is-active --quiet sddm || \
       systemctl is-active --quiet display-manager; then
        
        systemctl set-default multi-user.target
        log "System will boot to console mode (TTY) on next restart"
        log "Graphical interface disabled to save resources"
        
        return 0
    else
        log "No graphical interface detected, system already in console mode"
        return 0
    fi
}

enable_graphical_interface() {
    log "Re-enabling graphical interface..."
    
    systemctl set-default graphical.target
    log "System will boot to graphical mode on next restart"
    
    return 0
}

interactive_mode() {
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

    install_packages
    stop_services

    if ! detect_interfaces; then
        exit 1
    fi

    AP_NAME=""
    while [ -z "$AP_NAME" ]
    do
        read -p "Enter Access Point name (SSID): " AP_NAME

        if [ -z "$AP_NAME" ]; then
            error "SSID cannot be empty"
        fi
    done

    AP_PASSWORD=""
    while [ -z "$AP_PASSWORD" ]
    do
        read -s -p "Enter Access Point password (minimum 8 characters): " AP_PASSWORD
        echo

        if [ -z "$AP_PASSWORD" ]; then
            error "Password cannot be empty"
        elif [ ${#AP_PASSWORD} -lt 8 ]; then
            error "Password must be at least 8 characters long"
            AP_PASSWORD=""
        fi
    done
    echo

    read -p "Enable router functionality after reboot? (y/N): " AP_reboot
    echo

    DISABLE_GUI=""
    if [[ ${AP_reboot^^} == "y" ]]; then
        read -p "Disable graphical interface to save resources (boot to TTY)? (y/N): " DISABLE_GUI
        echo
    fi

    configure_persistent
    
    install_script

    if apply_router_config; then
        save_config
        
        if [[ ${AP_reboot^^} == "y" ]]; then
            create_systemd_service
            
            if [[ ${DISABLE_GUI^^} == "y" ]]; then
                disable_graphical_interface
            fi
            
            log "Services are enabled for automatic startup via router-mode.service"
            log "Script installed as: $SCRIPT_INSTALL_PATH"
        else
            log "Router will NOT persist after reboot. Run this script again after restart if needed."
            systemctl disable hostapd 2>/dev/null || true
            systemctl disable dnsmasq 2>/dev/null || true
            systemctl disable netfilter-persistent 2>/dev/null || true
        fi

        trap - EXIT

        log "Router configuration completed successfully!"
        echo
        echo "================================================"
        echo "Access Point: $AP_NAME"
        echo "Password: $AP_PASSWORD"
        echo "Interface: $AP_IFACE"
        echo "Internet via: $WAN_IFACE"
        echo "LAN Gateway: $LAN_GW"
        echo "DHCP Range: $LAN_DHCP_START - $LAN_DHCP_END"
        echo "DNS Servers: $LAN_DNS"
        if [[ ${DISABLE_GUI^^} == "y" ]]; then
            echo "Boot Mode: Console (TTY) - Graphical interface disabled"
        fi
        echo "================================================"
        echo
        log "You can check the status with:"
        echo "  systemctl status router-mode.service"
        echo "  systemctl status hostapd dnsmasq"
        echo "  journalctl -u router-mode -f"
        echo "  journalctl -u hostapd -f"
        echo "  journalctl -u dnsmasq -f"
        echo
        log "To manage router mode manually:"
        echo "  sudo $SCRIPT_INSTALL_PATH"
        
        if [[ ${DISABLE_GUI^^} == "y" ]]; then
            echo
            warning "System will boot to console mode (TTY) after restart"
            log "To access TTY, use Ctrl+Alt+F1 to F6"
            log "To temporarily start GUI: sudo systemctl start gdm3 (or lightdm/sddm)"
            log "To permanently re-enable GUI: sudo systemctl set-default graphical.target"
        fi
    else
        error "Failed to configure router"
        exit 1
    fi
}

check_root

if [ "${1:-}" = "--service" ]; then
    service_mode_start
elif [ "${1:-}" = "--service-stop" ]; then
    service_mode_stop
    exit 0
fi

read -p "Do you wish to delete the configurations previously made with this script? (y/N): " AP_CLEAN
if [[ ${AP_CLEAN^^} == "y" ]]; then
    cleanup_router

    log "Cleaning complete"
    warning "A restart is recommended..."
    read -p "Would you like to restart? (y/N): " AP_RESTART
    if [[ ${AP_RESTART^^} == "y" ]]; then
        log "Restarting in 3 seconds..."
        sleep 3
        shutdown -r now
    fi
    
    exit 0
fi

interactive_mode
