#!/usr/bin/env bash
# =============================================================================
# mindspark_setup.sh — MindSpark Server Post-Installation Script
# Ubuntu 20.04 LTS / 24.04 LTS
#
# Performs:
#   1. AnyDesk installation (official repo)
#   2. Static IP configuration (Netplan)
#   3. Kea DHCP4 server installation & scope configuration
#   4. NTP synchronisation hardening
#   5. Google Chrome installation & policy configuration
#
# Usage:  sudo ./mindspark_setup.sh
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ----- Log file --------------------------------------------------------------
LOG_DIR="/var/log/mindspark"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

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

# ----- Cleanup / rollback trap -----------------------------------------------
PHASE="pre-flight"
NETPLAN_BACKUPS=()

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        error "Script failed during phase: ${PHASE} (exit code ${exit_code})"
        error "Full log saved to: ${LOG_FILE}"

        # Rollback netplan if we were in that phase and backups exist
        if [[ "$PHASE" == "netplan" || "$PHASE" == "post-netplan" ]] && [[ ${#NETPLAN_BACKUPS[@]} -gt 0 ]]; then
            warn "Rolling back Netplan configuration..."
            for backup in "${NETPLAN_BACKUPS[@]}"; do
                local original="${backup%.bak.*}"
                if [[ -f "$backup" ]]; then
                    cp "$backup" "$original"
                fi
            done
            # Remove the file we created
            rm -f "${NETPLAN_DIR:-/etc/netplan}/01-mindspark-static.yaml"
            netplan apply 2>/dev/null || true
            warn "Netplan rolled back to previous state."
        fi
    fi
}
trap cleanup EXIT

# ----- Pre-flight checks -----------------------------------------------------
info "MindSpark setup v${SCRIPT_VERSION} — $(date)"
info "Log file: ${LOG_FILE}"
echo ""

if [[ $EUID -ne 0 ]]; then
    info "Root privileges are required. Re-running with sudo..."
    exec sudo -k -- "$0" "$@"
fi

if [[ ! -r /etc/os-release ]]; then
    error "Cannot detect the operating system. /etc/os-release is missing."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    error "Unsupported OS '${PRETTY_NAME:-unknown}'. This script supports Ubuntu 20.04 LTS and 24.04 LTS only."
    exit 1
fi

UBUNTU_VERSION="${VERSION_ID:-unknown}"
case "$UBUNTU_VERSION" in
    20.04|24.04)
        info "Detected supported OS: ${PRETTY_NAME}"
        ;;
    *)
        error "Unsupported Ubuntu version '${UBUNTU_VERSION}'. Use Ubuntu 20.04 LTS or 24.04 LTS."
        exit 1
        ;;
esac

# ----- Paths (must come before any function that references them) ------------
NETPLAN_DIR="/etc/netplan"
KEA_CONF_DIR="/etc/kea"
KEA_CONF="${KEA_CONF_DIR}/kea-dhcp4.conf"
CHROME_POLICY_FILE="/etc/opt/chrome/policies/managed/mindspark.json"
CHROMIUM_POLICY_FILE="/etc/chromium/policies/managed/mindspark.json"

# Kea package and service names:
#   20.04 universe: package=kea-dhcp4-server  service=kea-dhcp4-server
#   24.04 main:     package=kea-dhcp4-server  service=kea-dhcp4-server
# (The package was never named 'kea-dhcp4' in Ubuntu — that name does not exist.)
KEA_PACKAGE="kea-dhcp4-server"
KEA_SERVICE="kea-dhcp4-server"

# --- Online connectivity check -----------------------------------------------
# Result is cached after the first call so subsequent callers pay no extra cost.
_ONLINE_CACHED=""
is_online() {
    if [[ -z "$_ONLINE_CACHED" ]]; then
        if (echo > /dev/tcp/8.8.8.8/53) 2>/dev/null || \
           (echo > /dev/tcp/1.1.1.1/53) 2>/dev/null; then
            _ONLINE_CACHED="yes"
        else
            _ONLINE_CACHED="no"
        fi
    fi
    [[ "$_ONLINE_CACHED" == "yes" ]]
}

# Waits up to $1 seconds (default 90) for internet connectivity to return.
# Resets _ONLINE_CACHED first so is_online() does a live probe each iteration.
wait_for_connectivity() {
    local timeout="${1:-90}" elapsed=0
    _ONLINE_CACHED=""
    if is_online; then return 0; fi
    info "Waiting for internet connectivity (up to ${timeout}s)..."
    while (( elapsed < timeout )); do
        sleep 3
        elapsed=$(( elapsed + 3 ))
        _ONLINE_CACHED=""
        if is_online; then
            success "Internet connectivity restored after ${elapsed}s"
            return 0
        fi
    done
    error "No internet connectivity after ${timeout}s."
    return 1
}

# --- Pre-flight runtime sanity (prevent running on already-broken systems) ---
check_runtime_health() {
    local failed=0

    if ! python3 --version >/dev/null 2>&1; then
        error "python3 failed to start. System runtime appears broken."
        failed=1
    fi

    if ! command -v netplan >/dev/null 2>&1; then
        error "netplan command is missing (netplan.io not installed or damaged)."
        failed=1
    elif ! netplan --help >/dev/null 2>&1; then
        error "netplan failed to start. System runtime appears broken."
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        echo ""
        error "SAFETY ABORT: core runtime tools are unhealthy before setup starts."
        error "This usually means mixed Ubuntu package versions (e.g., GLIBC mismatch)."
        error "Continuing could further damage the system; no changes were applied."
        echo ""
        if is_online; then
            warn "Online recovery (first attempt):"
            warn "  apt-get update"
            warn "  apt-get -f install"
            warn "  apt-get install --reinstall libc6 python3-minimal python3 netplan.io"
        else
            warn "Offline recovery: boot a matching Ubuntu Live USB and repair via chroot,"
            warn "or reinstall the OS if package repair is not possible."
        fi
        exit 1
    fi
}
check_runtime_health

# ---- Package helper: apt-only install (online required) ---------------------
_APT_UPDATED=0
ensure_apt_index() {
    if [[ $_APT_UPDATED -eq 0 ]]; then
        apt-get update -qq
        _APT_UPDATED=1
    fi
}

install_packages() {
    local to_install=()
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            continue
        fi
        to_install+=("$pkg")
    done

    [[ ${#to_install[@]} -eq 0 ]] && return 0

    if ! is_online; then
        error "Internet connection is required to install missing packages: ${to_install[*]}"
        return 1
    fi

    info "Installing via apt: ${to_install[*]}"
    ensure_apt_index
    apt-get install -y -qq --no-install-recommends "${to_install[@]}"
}

# --- AP MAC detection --------------------------------------------------------
# Top-level helper: reads ARP/neighbour tables on $1 excluding the server's own IP $2.
# Prints the first foreign MAC found; returns 1 if none.
_read_arp_table() {
    local iface="$1" server_ip="$2"
    local found=""

    # ip neigh — catches REACHABLE, STALE, DELAY entries (case-insensitive MAC)
    found=$(ip neigh show dev "$iface" 2>/dev/null \
        | grep -iv "^${server_ip}[[:space:]]" \
        | grep -iE 'lladdr [0-9a-f]{2}:' \
        | awk '{print $5}' \
        | grep -iv '^$' \
        | head -1)
    [[ -n "$found" ]] && { echo "$found"; return 0; }

    # arp -n — legacy table, sometimes has entries ip neigh doesn't
    found=$(arp -n 2>/dev/null \
        | awk -v iface="$iface" -v server="$server_ip" \
            'NR>1 && $1 != server && $5 == iface && $3 != "" && $3 != "(incomplete)" {print $3}' \
        | head -1)
    [[ -n "$found" ]] && { echo "$found"; return 0; }

    return 1
}

# Top-level helper: rate-limited arping sweep of the subnet to populate the ARP
# cache before detect_ap_mac polls it. Fires up to BATCH_SIZE probes concurrently
# to avoid flooding the link or triggering intrusion detection.
# Usage: _trigger_arp_sweep <iface> <server_ip> <subnet_prefix>
_trigger_arp_sweep() {
    local iface="$1" server_ip="$2" prefix="$3"
    local batch_size=10 batch_pids=()

    for _h in $(seq 1 254); do
        local target="${prefix}.${_h}"
        [[ "$target" == "$server_ip" ]] && continue

        if command -v arping &>/dev/null; then
            arping -c 1 -w 1 -I "$iface" "$target" &>/dev/null &
        else
            ping -c 1 -W 1 "$target" &>/dev/null &
        fi
        batch_pids+=($!)

        # Wait for the batch to drain before launching the next one
        if (( ${#batch_pids[@]} >= batch_size )); then
            wait "${batch_pids[@]}" 2>/dev/null || true
            batch_pids=()
        fi
    done
    # Wait for any remaining probes
    [[ ${#batch_pids[@]} -gt 0 ]] && { wait "${batch_pids[@]}" 2>/dev/null || true; }
}

# Probes $NET_IFACE for up to 60 s to discover the Access Point's MAC address.
# The AP has a static management IP in the subnet (not the gateway address) so we
# arping-scan the entire usable range to trigger an ARP reply from whatever IP the AP
# was pre-configured with. Falls back to the Kea leases file.
# Usage: detect_ap_mac <iface> <server_ip>
# Prints the MAC to stdout; returns 1 if not found.
detect_ap_mac() {
    local iface="$1" server_ip="$2"
    local mac="" subnet_prefix="${server_ip%.*}"

    info "Probing network to detect Access Point MAC address (up to 60 s)..."

    # Launch the rate-limited sweep in the background; don't block the polling loop
    _trigger_arp_sweep "$iface" "$server_ip" "$subnet_prefix" &
    local sweep_pid=$!

    for _ap_i in $(seq 1 60); do
        mac=$(_read_arp_table "$iface" "$server_ip" || true)
        if [[ -n "$mac" ]]; then
            # Clean up the background sweep before returning
            kill "$sweep_pid" 2>/dev/null || true
            wait "$sweep_pid" 2>/dev/null || true
            echo "$mac"
            return 0
        fi
        sleep 1
    done

    wait "$sweep_pid" 2>/dev/null || true

    # Fallback: parse Kea leases file — case-insensitive
    local leases_file="/var/lib/kea/dhcp4.leases"
    if [[ -f "$leases_file" ]]; then
        mac=$(grep -ioP '"hw-address"\s*:\s*"\K[0-9a-fA-F:]+' "$leases_file" \
            | tr '[:upper:]' '[:lower:]' | head -1)
        if [[ -n "$mac" ]]; then
            echo "$mac"
            return 0
        fi
    fi

    return 1
}

# --- Input validation -------------------------------------------------------
# Returns 0 if the argument is a valid dotted-decimal IPv4 address.
validate_ipv4() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "$ip" =~ $re ]]; then return 1; fi
    IFS='.' read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
        (( part >= 0 && part <= 255 )) || return 1
    done
    return 0
}

# Prompts for an IP, re-asking until valid. Usage: prompt_ip VAR PROMPT DEFAULT
prompt_ip() {
    local -n _pi_ref="$1"
    local prompt="$2" default="$3"
    while true; do
        read -rp "${prompt} [${default}]: " _pi_ref
        _pi_ref="${_pi_ref:-$default}"
        if validate_ipv4 "$_pi_ref"; then break; fi
        warn "'${_pi_ref}' is not a valid IPv4 address. Please try again."
    done
}

# Networking defaults
DEFAULT_SUBNET="10.10.10.0"
DEFAULT_NETMASK="255.255.255.0"
DEFAULT_GATEWAY="10.10.10.1"
DEFAULT_DNS="8.8.8.8"
DEFAULT_DNS2="8.8.4.4"
DEFAULT_DHCP_RANGE_START="10.10.10.100"
DEFAULT_DHCP_RANGE_END="10.10.10.200"
DEFAULT_DHCP_LEASE_TIME="600"
DEFAULT_DHCP_MAX_LEASE="7200"

# Country-specific network defaults
COUNTRY=""
DEFAULT_STATIC_IP=""

select_country() {
    if ! command -v whiptail &>/dev/null; then
        install_packages whiptail
    fi

    if ! command -v whiptail &>/dev/null; then
        warn "whiptail is not available. Falling back to text menu."
        select choice in "zambia" "south_africa"; do
            case "$choice" in
                zambia|south_africa)
                    echo "$choice"
                    return 0
                    ;;
                *)
                    warn "Invalid selection. Choose 1 or 2."
                    ;;
            esac
        done
        return 0
    fi

    local choice=""
    choice=$(whiptail \
        --title "MindSpark Country" \
        --menu "Select the server country:" \
        15 60 2 \
        "zambia" "Use Zambia network defaults" \
        "south_africa" "Use South Africa network defaults" \
        3>&1 1>&2 2>&3) || {
        error "Country selection cancelled."
        exit 1
    }

    echo "$choice"
}

# =============================================================================
# PHASE 1 — Gather information interactively
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   MindSpark Server Post-Installation Setup${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Optional server label ---------------------------------------------------
read -rp "Optional: enter MindSpark server number for labels/reporting only (press Enter to skip): " SERVER_NUM
SERVER_LABEL=""
if [[ -n "$SERVER_NUM" ]]; then
    # Validate only when provided: must be a positive integer
    if ! [[ "$SERVER_NUM" =~ ^[0-9]+$ ]] || [[ "$SERVER_NUM" -eq 0 ]]; then
        error "Server number must be a positive integer when provided."
        exit 1
    fi
    SERVER_LABEL="mindsparkserver${SERVER_NUM}"
fi

CURRENT_HOSTNAME="$(hostname)"

# --- Country ---------------------------------------------------------------
echo ""
COUNTRY_NORMALIZED="$(select_country)"

case "$COUNTRY_NORMALIZED" in
    zambia)
        COUNTRY="Zambia"
        DEFAULT_STATIC_IP="192.168.8.200"
        DEFAULT_SUBNET="192.168.8.0"
        DEFAULT_GATEWAY="192.168.8.1"
        DEFAULT_DHCP_RANGE_START="192.168.8.100"
        DEFAULT_DHCP_RANGE_END="192.168.8.199"
        ;;
    south\ africa|south_africa|sa)
        COUNTRY="South Africa"
        DEFAULT_STATIC_IP="192.168.0.200"
        # shellcheck disable=SC2034  # Overridden by country; used via $SUBNET later
        DEFAULT_SUBNET="192.168.0.0"
        DEFAULT_GATEWAY="192.168.0.1"
        DEFAULT_DHCP_RANGE_START="192.168.0.100"
        DEFAULT_DHCP_RANGE_END="192.168.0.199"
        ;;
    *)
        error "Unsupported country selection '${COUNTRY_NORMALIZED}'."
        exit 1
        ;;
esac

# --- Network interface -------------------------------------------------------
# Detect physical ethernet interfaces (exclude loopback, wireless, virtual bridges, docker, veth)
detect_ethernet_interfaces() {
    local ifaces=()
    local all_ifaces
    all_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//')

    for iface in $all_ifaces; do
        # Skip loopback
        [[ "$iface" == "lo" ]] && continue
        # Skip wireless (wl*)
        [[ "$iface" == wl* ]] && continue
        # Skip virtual/bridge/container interfaces
        [[ "$iface" == br* || "$iface" == docker* || "$iface" == veth* || "$iface" == virbr* ]] && continue

        # Check if it's a physical device (has a /sys/class/net/<iface>/device symlink)
        # or is a well-known ethernet naming pattern (en*, eth*)
        if [[ -d "/sys/class/net/${iface}/device" ]] || [[ "$iface" == en* ]] || [[ "$iface" == eth* ]]; then
            ifaces+=("$iface")
        fi
    done

    echo "${ifaces[@]}"
}

echo ""
read -ra ETHERNET_IFACES <<< "$(detect_ethernet_interfaces)"

if [[ ${#ETHERNET_IFACES[@]} -eq 0 ]]; then
    warn "No physical ethernet interface detected."
    echo ""
    echo -e "${BOLD}Please connect a USB ethernet adapter to this server now.${NC}"
    echo ""
    while true; do
        read -rp "Press Enter once the adapter is plugged in (or type 'quit' to abort): " WAIT_INPUT
        if [[ "${WAIT_INPUT,,}" == "quit" ]]; then
            error "Aborted by user. No changes were made."
            exit 1
        fi

        # Give the kernel a moment to register the device
        sleep 2

        read -ra ETHERNET_IFACES <<< "$(detect_ethernet_interfaces)"
        if [[ ${#ETHERNET_IFACES[@]} -gt 0 ]]; then
            success "Detected ethernet interface(s): ${ETHERNET_IFACES[*]}"
            break
        fi

        warn "Still no ethernet interface found. Check the adapter and try again."
    done
fi

if [[ ${#ETHERNET_IFACES[@]} -eq 1 ]]; then
    NET_IFACE="${ETHERNET_IFACES[0]}"
    info "Auto-selected the only ethernet interface: ${NET_IFACE}"
else
    echo ""
    info "Multiple ethernet interfaces detected:"
    for i in "${!ETHERNET_IFACES[@]}"; do
        local_ip=$(ip -4 addr show "${ETHERNET_IFACES[$i]}" 2>/dev/null | awk '/inet /{print $2}' || echo "no IP")
        local_state=$(ip -br link show "${ETHERNET_IFACES[$i]}" 2>/dev/null | awk '{print $2}' || echo "unknown")
        printf "  %d) %-16s  state: %-6s  ip: %s\n" "$((i+1))" "${ETHERNET_IFACES[$i]}" "$local_state" "$local_ip"
    done
    echo ""
    while true; do
        read -rp "Select the interface number to configure [1-${#ETHERNET_IFACES[@]}]: " IFACE_NUM
        if [[ "$IFACE_NUM" =~ ^[0-9]+$ ]] && (( IFACE_NUM >= 1 && IFACE_NUM <= ${#ETHERNET_IFACES[@]} )); then
            NET_IFACE="${ETHERNET_IFACES[$((IFACE_NUM-1))]}"
            break
        fi
        warn "Invalid selection. Enter a number between 1 and ${#ETHERNET_IFACES[@]}."
    done
fi

# Final validation: confirm the chosen interface is operationally present
if ! ip link show "$NET_IFACE" &>/dev/null; then
    error "Interface '${NET_IFACE}' disappeared. Check the adapter connection."
    exit 1
fi

info "Will configure interface: ${NET_IFACE}"

# --- Static IP ---------------------------------------------------------------
STATIC_IP="$DEFAULT_STATIC_IP"
info "Static IP is auto-assigned from country: ${STATIC_IP}"

# Validate netmask manually (not an IP probe but same format)
while true; do
    read -rp "Enter the subnet mask [${DEFAULT_NETMASK}]: " NETMASK
    NETMASK="${NETMASK:-$DEFAULT_NETMASK}"
    if validate_ipv4 "$NETMASK"; then break; fi
    warn "'${NETMASK}' is not a valid subnet mask. Please try again."
done

prompt_ip GATEWAY "Enter the gateway" "$DEFAULT_GATEWAY"
prompt_ip DNS     "Enter the primary DNS server" "$DEFAULT_DNS"
prompt_ip DNS2    "Enter the secondary DNS server" "$DEFAULT_DNS2"

# --- DHCP scope --------------------------------------------------------------
echo ""
printf "${BOLD}DHCP scope configuration${NC}\n"
prompt_ip DHCP_START "DHCP range start" "$DEFAULT_DHCP_RANGE_START"
prompt_ip DHCP_END   "DHCP range end  " "$DEFAULT_DHCP_RANGE_END"

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

# Calculate a safe AP management IP: first host address in the subnet that is
# not the server itself. Works for any prefix length, not just /24.
calculate_ap_mgmt_ip() {
    IFS='.' read -r -a net_parts <<< "$SUBNET"
    # Increment the last octet of the network address by 1 to get first host,
    # then by 2 if that collides with the server IP.
    local candidate
    candidate=$(printf "%d.%d.%d.%d" \
        "${net_parts[0]}" "${net_parts[1]}" "${net_parts[2]}" \
        $(( net_parts[3] + 1 )))
    if [[ "$candidate" == "$STATIC_IP" ]]; then
        candidate=$(printf "%d.%d.%d.%d" \
            "${net_parts[0]}" "${net_parts[1]}" "${net_parts[2]}" \
            $(( net_parts[3] + 2 )))
    fi
    echo "$candidate"
}
AP_MGMT_IP="$(calculate_ap_mgmt_ip)"
AP_MAC=""                      # Populated in Phase 3.6 after DHCP server starts

# Calculate broadcast address in pure bash (avoids mawk compl() incompatibility)
calculate_broadcast() {
    IFS='.' read -r -a ip_parts <<< "$STATIC_IP"
    IFS='.' read -r -a mask_parts <<< "$NETMASK"
    printf "%d.%d.%d.%d" \
        $(( ip_parts[0] | (255 - mask_parts[0]) )) \
        $(( ip_parts[1] | (255 - mask_parts[1]) )) \
        $(( ip_parts[2] | (255 - mask_parts[2]) )) \
        $(( ip_parts[3] | (255 - mask_parts[3]) ))
}
BROADCAST=$(calculate_broadcast)
CHROME_URL="http://${STATIC_IP}"
SYNC_STATUS_URL="${CHROME_URL}/Mindspark/SyncStatus.php"

# Grandstream APs (South Africa) have their own built-in DHCP server — kea is
# not needed and would conflict. Only install kea for Zambia.
if [[ "$COUNTRY_NORMALIZED" == "zambia" ]]; then
    NEEDS_DHCP=true
else
    NEEDS_DHCP=false
fi

# Determine what will happen for each component
IFACE_MAC=$(ip link show "$NET_IFACE" 2>/dev/null | awk '/link\/ether/{print $2}' || echo "unknown")
CHROME_STATUS="Install & configure"
if command -v google-chrome-stable &>/dev/null || command -v google-chrome &>/dev/null; then
    CHROME_STATUS="Already installed — will update policies only"
fi
ANYDESK_STATUS="Install & regenerate ID"
if command -v anydesk &>/dev/null; then
    ANYDESK_STATUS="Already installed — will regenerate ID only"
fi
DHCP_STATUS="Not required (Grandstream AP handles DHCP)"
if $NEEDS_DHCP; then
    DHCP_STATUS="Install & configure"
    if dpkg -s "$KEA_PACKAGE" &>/dev/null; then
        DHCP_STATUS="Already installed — will update configuration only"
    fi
fi

# =============================================================================
# PHASE 2 — Show summary and ask for confirmation
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   CONFIGURATION SUMMARY${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Hostname (current):${CYAN}${CURRENT_HOSTNAME}${NC}  (will remain unchanged)"
if [[ -n "$SERVER_LABEL" ]]; then
    echo -e "  Server label:      ${CYAN}${SERVER_LABEL}${NC}"
else
    echo -e "  Server label:      ${CYAN}(not set)${NC}"
fi
echo -e "  Country:           ${CYAN}${COUNTRY}${NC}"
echo -e "  Interface:         ${CYAN}${NET_IFACE}${NC}  (MAC: ${IFACE_MAC})"
echo -e "  Static IP:         ${CYAN}${STATIC_IP}/${CIDR}${NC}"
echo -e "  Gateway:           ${CYAN}${GATEWAY}${NC}"
echo -e "  DNS (primary):     ${CYAN}${DNS}${NC}"
echo -e "  DNS (secondary):   ${CYAN}${DNS2}${NC}"
echo ""
if $NEEDS_DHCP; then
    echo -e "  DHCP subnet:       ${CYAN}${SUBNET}/${CIDR}${NC}"
    echo -e "  DHCP range:        ${CYAN}${DHCP_START} – ${DHCP_END}${NC}"
    echo -e "  AP reserved IP:    ${CYAN}${AP_MGMT_IP}${NC}  (outside pool — assigned once AP is detected)"
    echo -e "  Default lease:     ${CYAN}${LEASE_TIME}s${NC}"
    echo -e "  Max lease:         ${CYAN}${MAX_LEASE}s${NC}"
fi
echo -e "  Chrome URL:        ${CYAN}${CHROME_URL}${NC}"
echo -e "  Sync Status URL:   ${CYAN}${SYNC_STATUS_URL}${NC}"
echo ""
echo -e "  Chrome:            ${CYAN}${CHROME_STATUS}${NC}"
echo -e "  AnyDesk:           ${CYAN}${ANYDESK_STATUS}${NC}"
echo -e "  DHCP server:       ${CYAN}${DHCP_STATUS}${NC}"
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

read -rp "Apply this configuration? (yes/no): " CONFIRM
if [[ "${CONFIRM,,}" != "yes" ]]; then
    warn "Aborted by user. No changes were made."
    exit 0
fi

PHASE="applying"
echo ""
info "Starting configuration..."
echo ""

# Packages are installed from apt repositories only.

# =============================================================================
# PHASE 3 — Apply configuration
# =============================================================================

# ----- 3.1  Hostname policy --------------------------------------------------
PHASE="hostname-policy"
info "Leaving system hostname unchanged: $(hostname)"

# ----- 3.2  Configure Netplan (static IP) ------------------------------------
PHASE="netplan"
info "Configuring Netplan for static IP..."
NETPLAN_FILE="${NETPLAN_DIR}/01-mindspark-static.yaml"

# Auto-detect which renderer is active on this system.
# Ubuntu Desktop uses NetworkManager; Ubuntu Server uses networkd.
detect_netplan_renderer() {
    if systemctl is-active --quiet NetworkManager; then
        echo "NetworkManager"
    elif systemctl is-active --quiet systemd-networkd; then
        echo "networkd"
    else
        # Fall back to whichever is enabled
        if systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
            echo "NetworkManager"
        else
            echo "networkd"
        fi
    fi
}
NETPLAN_RENDERER="$(detect_netplan_renderer)"
info "Detected active network renderer: ${NETPLAN_RENDERER}"

# Back up existing configs (tracked for rollback)
for f in "${NETPLAN_DIR}"/*.yaml; do
    if [[ -f "$f" ]]; then
        local_backup="${f}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$f" "$local_backup"
        NETPLAN_BACKUPS+=("$local_backup")
    fi
done

cat > "$NETPLAN_FILE" <<NETPLAN_EOF
# Managed by mindspark_setup.sh — do not edit manually
network:
  version: 2
  renderer: ${NETPLAN_RENDERER}
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
          - ${DNS2}
NETPLAN_EOF

chmod 600 "$NETPLAN_FILE"
netplan apply

# For NetworkManager renderer, force NM to bring up the interface immediately.
# netplan apply generates the NM connection profile but NM may not activate it
# automatically if the interface was previously managed by a DHCP connection.
if [[ "$NETPLAN_RENDERER" == "NetworkManager" ]]; then
    nmcli connection reload 2>/dev/null || true
    nmcli device connect "$NET_IFACE" 2>/dev/null || true
    sleep 5
else
    sleep 3
fi

# netplan apply (and NM connection reload) can briefly drop the WiFi connection
# that is providing internet access.  Reset the cached online state and wait.
wait_for_connectivity 90

PHASE="post-netplan"
success "Netplan configured (${NETPLAN_FILE}) using renderer: ${NETPLAN_RENDERER}"

# ----- 3.3  Install & configure Google Chrome --------------------------------
PHASE="chrome"
install_google_chrome() {
    if command -v google-chrome-stable &>/dev/null || command -v google-chrome &>/dev/null; then
        success "Google Chrome is already installed — skipping installation"
        return 0
    fi

    if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
        warn "Skipping Google Chrome install: google-chrome-stable is only configured for amd64."
        return 0
    fi

    info "Installing Google Chrome from online repository..."
    install_packages ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
    chmod a+r /etc/apt/keyrings/google-chrome.gpg

    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list

    ensure_apt_index
    apt-get install -y -qq google-chrome-stable
    success "Google Chrome installed"
}

write_chrome_policy() {
    local policy_file="$1"
    install -m 0755 -d "$(dirname "$policy_file")"
    cat > "$policy_file" <<CHROME_POLICY_EOF
{
    "PasswordManagerEnabled": false,
    "AutoSignInEnabled": false,
    "AutofillAddressEnabled": false,
    "AutofillCreditCardEnabled": false,
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "SearchSuggestEnabled": false,
    "MetricsReportingEnabled": false,
    "UrlKeyedAnonymizedDataCollectionEnabled": false,
    "HomepageLocation": "${CHROME_URL}",
    "HomepageIsNewTabPage": false,
    "ShowHomeButton": true,
    "RestoreOnStartup": 4,
    "RestoreOnStartupURLs": [
        "${CHROME_URL}"
    ],
    "ManagedBookmarks": [
        {
            "toplevel_name": "MindSpark"
        },
        {
            "name": "MindSpark",
            "url": "${CHROME_URL}"
        },
        {
            "name": "Sync Status",
            "url": "${SYNC_STATUS_URL}"
        }
    ]
}
CHROME_POLICY_EOF
    chmod 644 "$policy_file"
}

info "Installing/configuring Chrome policies..."
install_google_chrome
write_chrome_policy "$CHROME_POLICY_FILE"
write_chrome_policy "$CHROMIUM_POLICY_FILE"
success "Chrome policies written for homepage, bookmark, password, and Google services settings"

# ----- 3.4  Install AnyDesk --------------------------------------------------
PHASE="anydesk"
get_anydesk_id() {
    anydesk --get-id 2>/dev/null | tr -dc '0-9'
}

reset_anydesk_state() {
    # Removing persisted AnyDesk state forces regeneration of a fresh ID.
    systemctl stop anydesk.service 2>/dev/null || true
    if [[ -f /etc/anydesk/service.conf ]]; then
        cp /etc/anydesk/service.conf /etc/anydesk/service-backup.conf
    fi
    rm -f /etc/anydesk/service.conf
    rm -rf /var/lib/anydesk/*
}

info "Ensuring AnyDesk is installed..."
if command -v anydesk &>/dev/null; then
    success "AnyDesk is already installed — skipping installation"
else
    info "Installing AnyDesk from online repository..."
    install_packages ca-certificates curl gnupg

    # Add AnyDesk GPG key and repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY \
        | gpg --dearmor -o /etc/apt/keyrings/anydesk.gpg
    chmod a+r /etc/apt/keyrings/anydesk.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" \
        > /etc/apt/sources.list.d/anydesk.list

    ensure_apt_index
    apt-get install -y -qq anydesk
    success "AnyDesk installed"
fi

PREV_ANYDESK_ID=""
if command -v anydesk &>/dev/null; then
    PREV_ANYDESK_ID="$(get_anydesk_id || true)"
fi

if command -v anydesk &>/dev/null; then
    info "Resetting AnyDesk local state to regenerate the AnyDesk ID..."
    ATTEMPT=1
    MAX_ATTEMPTS=2
    NEW_ANYDESK_ID=""

    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
        reset_anydesk_state
        systemctl enable --now anydesk.service

        NEW_ANYDESK_ID=""
        for _loop_i in {1..15}; do
            NEW_ANYDESK_ID="$(get_anydesk_id || true)"
            [[ -n "$NEW_ANYDESK_ID" ]] && break
            sleep 1
        done

        if [[ -z "$PREV_ANYDESK_ID" || -z "$NEW_ANYDESK_ID" || "$NEW_ANYDESK_ID" != "$PREV_ANYDESK_ID" ]]; then
            break
        fi

        warn "AnyDesk ID unchanged after reset attempt ${ATTEMPT}; retrying once..."
        ATTEMPT=$((ATTEMPT + 1))
    done

    if [[ -n "$NEW_ANYDESK_ID" ]]; then
        if [[ -n "$PREV_ANYDESK_ID" && "$NEW_ANYDESK_ID" == "$PREV_ANYDESK_ID" ]]; then
            warn "AnyDesk ID is still ${NEW_ANYDESK_ID}. Rotation may be restricted by host identity."
        else
            success "AnyDesk is ready with ID: ${NEW_ANYDESK_ID}"
        fi
    else
        warn "AnyDesk installed, but could not read an AnyDesk ID yet."
    fi
else
    warn "AnyDesk is not installed; skipping AnyDesk ID reset workflow."
fi

# ----- 3.5  Install & configure Kea DHCP4 (Zambia only) --------------------
PHASE="dhcp"

if ! $NEEDS_DHCP; then
    info "Skipping Kea DHCP4 installation — Grandstream AP handles DHCP for South Africa"
fi

# On Ubuntu 20.04 kea is in universe; on 24.04 it is in main.
if $NEEDS_DHCP; then
if dpkg -s "$KEA_PACKAGE" &>/dev/null; then
    success "${KEA_PACKAGE} is already installed — skipping installation"
else
    # Ubuntu 20.04 ships kea in the 'universe' component — ensure it is enabled.
    if [[ "$UBUNTU_VERSION" == "20.04" ]]; then
        info "Enabling universe repository for Ubuntu 20.04..."
        if ! grep -qr '^deb .* universe' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            add-apt-repository -y universe
            _APT_UPDATED=0   # Force re-index after adding universe
        fi
    fi
    info "Installing ${KEA_PACKAGE}..."
    if ! install_packages "$KEA_PACKAGE"; then
        error "Failed to install ${KEA_PACKAGE}. Ensure internet access is available."
        exit 1
    fi
    success "${KEA_PACKAGE} installed"
fi

mkdir -p "$KEA_CONF_DIR"
[[ -f "$KEA_CONF" ]] && cp "$KEA_CONF" "${KEA_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# Build the AP reservation block — populated by Phase 3.6 after detection.
# Written as a placeholder now; Phase 3.6 rewrites the full file once the MAC is known.
AP_RESERVATION_JSON=""

write_kea_conf() {
    local ap_block="$1"
    cat > "$KEA_CONF" <<KEA_EOF
{
    "Dhcp4": {
        "interfaces-config": {
            "interfaces": [ "${NET_IFACE}" ],
            "service-sockets-require-all": false,
            "service-sockets-max-retries": 5,
            "service-sockets-retry-wait-time": 5000
        },
        "lease-database": {
            "type": "memfile",
            "persist": true,
            "name": "/var/lib/kea/dhcp4.leases"
        },
        "valid-lifetime": ${LEASE_TIME},
        "max-valid-lifetime": ${MAX_LEASE},
        "option-data": [
            { "name": "routers",             "data": "${GATEWAY}" },
            { "name": "domain-name-servers", "data": "${DNS}, ${DNS2}" },
            { "name": "broadcast-address",   "data": "${BROADCAST}" }
        ],
        "subnet4": [
            {
                "subnet": "${SUBNET}/${CIDR}",
                "pools": [ { "pool": "${DHCP_START} - ${DHCP_END}" } ]${ap_block}
            }
        ]
    }
}
KEA_EOF
    chmod 640 "$KEA_CONF"
    chown root:_kea "$KEA_CONF" 2>/dev/null || chown root:root "$KEA_CONF"
}

write_kea_conf ""
success "Kea DHCP4 configuration written to ${KEA_CONF}"

# Validate config
if ! kea-dhcp4 -t "$KEA_CONF" 2>/dev/null; then
    error "kea-dhcp4 config test failed — check ${KEA_CONF}"
    kea-dhcp4 -t "$KEA_CONF" || true
    exit 1
fi

# Create a persistent systemd drop-in so kea auto-restarts indefinitely when
# the AP is not yet connected (service-sockets-require-all=false handles the
# socket-open side; this handles any other transient start failure).
mkdir -p "/etc/systemd/system/${KEA_SERVICE}.service.d"
cat > "/etc/systemd/system/${KEA_SERVICE}.service.d/mindspark-restart.conf" <<DROPIN_EOF
[Service]
Restart=on-failure
RestartSec=15s
StartLimitIntervalSec=0
DROPIN_EOF
systemctl daemon-reload
systemctl enable "$KEA_SERVICE"
if systemctl restart "$KEA_SERVICE"; then
    success "${KEA_SERVICE} enabled and started"
else
    warn "${KEA_SERVICE} did not start immediately — expected if the AP is not yet connected. It will retry every 15 s automatically."
    # Reset the failed state so systemd's restart logic kicks in
    systemctl reset-failed "$KEA_SERVICE" 2>/dev/null || true
    systemctl start "$KEA_SERVICE" 2>/dev/null || true
fi

fi  # end NEEDS_DHCP — phase 3.5

# ----- 3.6  Detect Access Point MAC and add static reservation ---------------
PHASE="ap-mac-detection"
if $NEEDS_DHCP; then

# Ensure arping is available — it is the most reliable ARP probe tool
if ! command -v arping &>/dev/null; then
    info "Installing arping for AP MAC detection..."
    install_packages iputils-arping 2>/dev/null || true
fi

info "Attempting to detect Access Point MAC address on ${NET_IFACE}..."

if AP_MAC=$(detect_ap_mac "$NET_IFACE" "$STATIC_IP"); then
    success "Access Point MAC detected: ${AP_MAC}"

    # Build the Kea reservation JSON block and rewrite the full config atomically
    AP_RESERVATION_JSON=",
                \"reservations\": [
                    {
                        \"hw-address\": \"${AP_MAC}\",
                        \"ip-address\": \"${AP_MGMT_IP}\"
                    }
                ]"

    write_kea_conf "$AP_RESERVATION_JSON"

    if kea-dhcp4 -t "$KEA_CONF" 2>/dev/null; then
        systemctl restart "$KEA_SERVICE" || true
        success "AP static reservation added: ${AP_MAC} → ${AP_MGMT_IP}"
    else
        warn "Kea config validation failed after adding AP reservation — restoring base config"
        write_kea_conf ""
        systemctl restart "$KEA_SERVICE" || true
        AP_MAC="(detected but reservation failed — add manually)"
    fi
else
    warn "Access Point not detected on ${NET_IFACE} within 60 seconds."
    warn "If the AP is not yet connected, rerun the script or add the reservation manually."
    AP_MAC="(not detected)"
fi
fi  # end NEEDS_DHCP — phase 3.6

# ----- 3.7  NTP hardening ----------------------------------------------------
PHASE="ntp"
info "Configuring NTP synchronisation..."

# systemd-timesyncd is built-in to Ubuntu — no extra package needed.
# Override the fallback NTP server to use well-known public servers.
NTP_CONF="/etc/systemd/timesyncd.conf.d/mindspark.conf"
mkdir -p "$(dirname "$NTP_CONF")"
cat > "$NTP_CONF" <<NTP_EOF
[Time]
NTP=time.cloudflare.com ntp.ubuntu.com
FallbackNTP=0.ubuntu.pool.ntp.org 1.ubuntu.pool.ntp.org
NTP_EOF

timedatectl set-ntp true
systemctl restart systemd-timesyncd
success "NTP configured (time.cloudflare.com, ntp.ubuntu.com)"

# =============================================================================
# PHASE 4 — Verification
# =============================================================================
PHASE="verification"
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}   VERIFICATION${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""

ERRORS=0

# Check hostname (informational only; hostname is intentionally unchanged)
CURRENT_HOSTNAME=$(hostname)
success "Hostname is ${CURRENT_HOSTNAME} (unchanged by script)"

# Check static IP — retry for up to 30 seconds to allow renderer time to apply
STATIC_IP_OK=false
for _i in $(seq 1 30); do
    if ip addr show "$NET_IFACE" 2>/dev/null | grep -q "${STATIC_IP}"; then
        STATIC_IP_OK=true
        break
    fi
    sleep 1
done
if $STATIC_IP_OK; then
    success "Static IP ${STATIC_IP} is assigned to ${NET_IFACE}"
else
    error "Static IP ${STATIC_IP} not found on ${NET_IFACE} after 30 s"
    info "Current addresses on ${NET_IFACE}:"
    ip addr show "$NET_IFACE" >&2 || true
    ERRORS=$((ERRORS + 1))
fi

# Check AnyDesk
if command -v anydesk &>/dev/null; then
    ANYDESK_VER="$(anydesk --version 2>/dev/null || echo 'version unknown')"
    ANYDESK_ID_CHECK="$(get_anydesk_id || true)"
    if [[ -n "$ANYDESK_ID_CHECK" ]]; then
        success "AnyDesk is installed (${ANYDESK_VER}) with ID ${ANYDESK_ID_CHECK}"
    else
        warn "AnyDesk is installed (${ANYDESK_VER}) but ID could not be read"
    fi
else
    error "AnyDesk is not installed"
    ERRORS=$((ERRORS + 1))
fi

# Check Chrome policy
if [[ -f "$CHROME_POLICY_FILE" ]]; then
    success "Chrome policy is configured for ${CHROME_URL}"
else
    error "Chrome policy file is missing"
    ERRORS=$((ERRORS + 1))
fi

# Check DHCP server (Zambia only)
DHCP_ERROR=false
if $NEEDS_DHCP; then
    if systemctl is-active --quiet "$KEA_SERVICE"; then
        success "${KEA_SERVICE} is running"
    else
        warn "${KEA_SERVICE} is not running — expected if the AP is not yet plugged in (auto-retries every 15 s)"
        DHCP_ERROR=true
    fi
    # Report Access Point MAC
    if [[ -n "$AP_MAC" && "$AP_MAC" != "(not detected)" && "$AP_MAC" != *"failed"* ]]; then
        success "Access Point MAC: ${AP_MAC}  →  reserved IP: ${AP_MGMT_IP}"
    else
        warn "Access Point MAC: ${AP_MAC}"
        warn "To add a reservation later, edit ${KEA_CONF} and restart kea-dhcp4"
    fi
else
    success "DHCP: handled by Grandstream AP (kea not installed)"
fi

# Check NTP
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
    success "NTP is synchronised"
else
    warn "NTP not yet synchronised — will complete once internet is available"
fi

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
info "Full log saved to: ${LOG_FILE}"
PHASE="done"

if [[ $ERRORS -eq 0 ]]; then
    # Only the DHCP warning (or nothing) — still reboot
    if $DHCP_ERROR; then
        echo ""
        printf "${YELLOW}${BOLD}  Setup complete with 1 expected warning:\n${NC}"
        printf "${YELLOW}${BOLD}  kea-dhcp4 will auto-retry once the Access Point is plugged in.\n${NC}"
    else
        echo ""
        printf "${GREEN}${BOLD}  All checks passed — setup complete!\n${NC}"
    fi
    echo ""
    printf "${GREEN}${BOLD}  The system will reboot in 10 seconds...\n${NC}"
    echo ""
    sleep 10
    reboot
else
    echo -e "${RED}${BOLD}  ${ERRORS} critical check(s) failed — review the errors above.${NC}"
    echo -e "${RED}${BOLD}  The system will NOT reboot until these are resolved.${NC}"
    echo ""
fi
