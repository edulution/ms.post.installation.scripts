#!/usr/bin/env bash
# =============================================================================
# mindspark_setup.sh — MindSpark Server Post-Installation Script
# Ubuntu 24.04 LTS
#
# Performs:
#   1. AnyDesk installation (official repo)
#   2. Static IP configuration (Netplan)
#   3. isc-dhcp-server installation & DHCP scope configuration
#
# Usage:  sudo ./mindspark_setup.sh
# =============================================================================

set -euo pipefail

# ----- Colour helpers --------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

info()    { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ----- Pre-flight checks -----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

# ----- Defaults (edit these or override via the prompts) ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETPLAN_DIR="/etc/netplan"
DHCP_CONF="/etc/dhcp/dhcpd.conf"
DHCP_DEFAULT="/etc/default/isc-dhcp-server"

# Networking defaults
DEFAULT_SUBNET="10.10.10.0"
DEFAULT_NETMASK="255.255.255.0"
DEFAULT_GATEWAY="10.10.10.1"
DEFAULT_DNS="8.8.8.8"
DEFAULT_DHCP_RANGE_START="10.10.10.100"
DEFAULT_DHCP_RANGE_END="10.10.10.200"
DEFAULT_DHCP_LEASE_TIME="600"
DEFAULT_DHCP_MAX_LEASE="7200"

# =============================================================================
# PHASE 1 — Gather information interactively
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   MindSpark Server Post-Installation Setup${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Server number -----------------------------------------------------------
read -rp "Enter the MindSpark server number (e.g. 1, 2, 3): " SERVER_NUM
# Validate: must be a positive integer
if ! [[ "$SERVER_NUM" =~ ^[0-9]+$ ]] || [[ "$SERVER_NUM" -eq 0 ]]; then
    error "Server number must be a positive integer."
    exit 1
fi
HOSTNAME="mindsparkserver${SERVER_NUM}"

# --- Network interface -------------------------------------------------------
echo ""
info "Detected network interfaces:"
ip -br link show | grep -v lo
echo ""
read -rp "Enter the network interface to configure (e.g. eth0, ens33): " NET_IFACE
# Validate interface exists
if ! ip link show "$NET_IFACE" &>/dev/null; then
    error "Interface '$NET_IFACE' not found."
    exit 1
fi

# --- Static IP ---------------------------------------------------------------
read -rp "Enter the static IP for this server [${DEFAULT_GATEWAY%.*}.${SERVER_NUM}]: " STATIC_IP
STATIC_IP="${STATIC_IP:-${DEFAULT_GATEWAY%.*}.${SERVER_NUM}}"

read -rp "Enter the subnet mask [${DEFAULT_NETMASK}]: " NETMASK
NETMASK="${NETMASK:-$DEFAULT_NETMASK}"

read -rp "Enter the gateway [${DEFAULT_GATEWAY}]: " GATEWAY
GATEWAY="${GATEWAY:-$DEFAULT_GATEWAY}"

read -rp "Enter the DNS server [${DEFAULT_DNS}]: " DNS
DNS="${DNS:-$DEFAULT_DNS}"

# --- DHCP scope --------------------------------------------------------------
echo ""
echo -e "${BOLD}DHCP scope configuration${NC}"
read -rp "DHCP range start [${DEFAULT_DHCP_RANGE_START}]: " DHCP_START
DHCP_START="${DHCP_START:-$DEFAULT_DHCP_RANGE_START}"

read -rp "DHCP range end   [${DEFAULT_DHCP_RANGE_END}]: " DHCP_END
DHCP_END="${DHCP_END:-$DEFAULT_DHCP_RANGE_END}"

read -rp "Default lease time (seconds) [${DEFAULT_DHCP_LEASE_TIME}]: " LEASE_TIME
LEASE_TIME="${LEASE_TIME:-$DEFAULT_DHCP_LEASE_TIME}"

read -rp "Max lease time (seconds) [${DEFAULT_DHCP_MAX_LEASE}]: " MAX_LEASE
MAX_LEASE="${MAX_LEASE:-$DEFAULT_DHCP_MAX_LEASE}"

# Calculate CIDR prefix from netmask
cidr_from_netmask() {
    local mask="$1" cidr=0
    IFS='.' read -r -a octets <<< "$mask"
    for octet in "${octets[@]}"; do
        while [[ $octet -gt 0 ]]; do
            cidr=$(( cidr + (octet & 1) ))
            octet=$(( octet >> 1 ))
        done
    done
    echo "$cidr"
}
CIDR=$(cidr_from_netmask "$NETMASK")

# Calculate subnet address for DHCP config
calculate_subnet() {
    IFS='.' read -r -a ip_parts <<< "$STATIC_IP"
    IFS='.' read -r -a mask_parts <<< "$NETMASK"
    printf "%d.%d.%d.%d" \
        $(( ip_parts[0] & mask_parts[0] )) \
        $(( ip_parts[1] & mask_parts[1] )) \
        $(( ip_parts[2] & mask_parts[2] )) \
        $(( ip_parts[3] & mask_parts[3] ))
}
SUBNET=$(calculate_subnet)

# =============================================================================
# PHASE 2 — Show summary and ask for confirmation
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   CONFIGURATION SUMMARY${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Hostname:          ${CYAN}${HOSTNAME}${NC}"
echo -e "  Interface:         ${CYAN}${NET_IFACE}${NC}"
echo -e "  Static IP:         ${CYAN}${STATIC_IP}/${CIDR}${NC}"
echo -e "  Gateway:           ${CYAN}${GATEWAY}${NC}"
echo -e "  DNS:               ${CYAN}${DNS}${NC}"
echo ""
echo -e "  DHCP subnet:       ${CYAN}${SUBNET}/${CIDR}${NC}"
echo -e "  DHCP range:        ${CYAN}${DHCP_START} – ${DHCP_END}${NC}"
echo -e "  Default lease:     ${CYAN}${LEASE_TIME}s${NC}"
echo -e "  Max lease:         ${CYAN}${MAX_LEASE}s${NC}"
echo ""
echo -e "  AnyDesk:           ${CYAN}Will be installed from official repo${NC}"
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

read -rp "Apply this configuration? (yes/no): " CONFIRM
if [[ "${CONFIRM,,}" != "yes" ]]; then
    warn "Aborted by user. No changes were made."
    exit 0
fi

echo ""
info "Starting configuration..."
echo ""

# =============================================================================
# PHASE 3 — Apply configuration
# =============================================================================

# ----- 3.1  Set hostname -----------------------------------------------------
info "Setting hostname to '${HOSTNAME}'..."
hostnamectl set-hostname "$HOSTNAME"
# Update /etc/hosts
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
else
    echo -e "127.0.1.1\t${HOSTNAME}" >> /etc/hosts
fi
success "Hostname set to ${HOSTNAME}"

# ----- 3.2  Configure Netplan (static IP) ------------------------------------
info "Configuring Netplan for static IP..."
NETPLAN_FILE="${NETPLAN_DIR}/01-mindspark-static.yaml"

# Back up existing configs
for f in "${NETPLAN_DIR}"/*.yaml; do
    [[ -f "$f" ]] && cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
done

cat > "$NETPLAN_FILE" <<NETPLAN_EOF
# Managed by mindspark_setup.sh — do not edit manually
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS}
NETPLAN_EOF

chmod 600 "$NETPLAN_FILE"
netplan apply
success "Netplan configured (${NETPLAN_FILE})"

# ----- 3.3  Install AnyDesk --------------------------------------------------
info "Installing AnyDesk..."
if command -v anydesk &>/dev/null; then
    warn "AnyDesk is already installed — skipping."
else
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    # Add AnyDesk GPG key and repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY \
        | gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg
    chmod a+r /etc/apt/keyrings/anydesk.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" \
        > /etc/apt/sources.list.d/anydesk.list

    apt-get update -qq
    apt-get install -y -qq anydesk
    success "AnyDesk installed"
fi

# ----- 3.4  Install & configure isc-dhcp-server ------------------------------
info "Installing isc-dhcp-server..."
apt-get install -y -qq isc-dhcp-server

# Back up existing DHCP config
[[ -f "$DHCP_CONF" ]] && cp "$DHCP_CONF" "${DHCP_CONF}.bak.$(date +%Y%m%d%H%M%S)"

cat > "$DHCP_CONF" <<DHCP_EOF
# Managed by mindspark_setup.sh — do not edit manually
# MindSpark DHCP configuration

authoritative;

default-lease-time ${LEASE_TIME};
max-lease-time ${MAX_LEASE};

subnet ${SUBNET} netmask ${NETMASK} {
    range ${DHCP_START} ${DHCP_END};
    option routers ${GATEWAY};
    option domain-name-servers ${DNS};
    option broadcast-address $(echo "$SUBNET" | awk -F. -v m="$NETMASK" '
        BEGIN { split(m,M,".") }
        { printf "%d.%d.%d.%d",
            or($1, compl(M[1]) % 256),
            or($2, compl(M[2]) % 256),
            or($3, compl(M[3]) % 256),
            or($4, compl(M[4]) % 256) }');
}
DHCP_EOF

# Set the listening interface
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${NET_IFACE}\"/" "$DHCP_DEFAULT"
success "DHCP configuration written to ${DHCP_CONF}"

# Enable and restart DHCP server
systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server
success "isc-dhcp-server enabled and started"

# =============================================================================
# PHASE 4 — Verification
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   VERIFICATION${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

ERRORS=0

# Check hostname
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" == "$HOSTNAME" ]]; then
    success "Hostname is ${CURRENT_HOSTNAME}"
else
    error "Hostname mismatch: expected ${HOSTNAME}, got ${CURRENT_HOSTNAME}"
    ERRORS=$((ERRORS + 1))
fi

# Check static IP
if ip addr show "$NET_IFACE" | grep -q "${STATIC_IP}"; then
    success "Static IP ${STATIC_IP} is assigned to ${NET_IFACE}"
else
    error "Static IP ${STATIC_IP} not found on ${NET_IFACE}"
    ERRORS=$((ERRORS + 1))
fi

# Check AnyDesk
if command -v anydesk &>/dev/null; then
    success "AnyDesk is installed ($(anydesk --version 2>/dev/null || echo 'version unknown'))"
else
    error "AnyDesk is not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check DHCP server
if systemctl is-active --quiet isc-dhcp-server; then
    success "isc-dhcp-server is running"
else
    error "isc-dhcp-server is NOT running"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All checks passed — setup complete!${NC}"
else
    echo -e "${RED}${BOLD}  ${ERRORS} check(s) failed — review the errors above.${NC}"
fi
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
