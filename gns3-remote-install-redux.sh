#!/usr/bin/env bash

# gns3-remote-install-redux.sh
# Install GNS3 on a remote Ubuntu LTS server.
#
# Based on the upstream GNS3 remote installer, rewritten to:
#   - consolidate all apt calls into a single pass
#   - add preflight validation (commands, ports, kernel modules, CPU virt)
#   - add WireGuard as a VPN option alongside OpenVPN
#   - remove IOU support entirely
#   - ensure the invoking user (SUDO_USER) gets added to all required groups
#   - improve idempotency, error recovery, and logging
#
# Usage: sudo ./gns3-remote-install-redux.sh [OPTIONS]
#   --with-openvpn            Install and configure OpenVPN
#   --with-wireguard          Install and configure WireGuard
#   --with-welcome            Install GNS3-VM welcome.py console UI
#   --without-kvm             Disable KVM (degrades Qemu performance)
#   --without-docker          Skip Docker installation
#   --without-firewall        Skip automatic UFW rule configuration
#   --without-system-upgrade  Skip apt upgrade
#   --unstable                Use GNS3 unstable PPA
#   --custom-repository REPO  Use a custom GNS3 PPA name
#   -h, --help                Show this help

# ─── Strict mode (after arg parsing, before any real work) ────────────────────
# We delay `set -euo pipefail` until after option parsing so getopt failures
# don't kill the script before we can print help.

# ─── Constants ────────────────────────────────────────────────────────────────

readonly DOCKER_BASE_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly GNS3_USER="gns3"
readonly GNS3_HOME="/opt/gns3"
readonly GNS3_CONF_DIR="/etc/gns3"
readonly GNS3_SERVICE_FILE="/lib/systemd/system/gns3.service"
readonly CONFIG_SERVE_PORT=8003
readonly CONFIG_SERVE_DIR="/var/lib/gns3-config-serve"
readonly CONFIG_SERVE_HOURS=2

# ─── Colors ───────────────────────────────────────────────────────────────────

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1" >&2; }
log_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$1" >&2; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1" >&2; }
log_error() { printf "${RED}[FAIL]${NC}  %s\n" "$1" >&2; }
log_fatal() { printf "${RED}[FATAL]${NC} %s\n" "$1" >&2; exit 1; }

# ─── Mutable arrays (built up by option flags) ───────────────────────────────

REQUIRED_CMDS=(apt apt-add-repository dpkg curl chown chmod useradd usermod lsmod systemctl ss openssl)
REQUIRED_PORTS=(3080)
REQUIRED_GROUPS=(kvm ubridge)
REQUIRED_MODS=(kvm)

REQUIRED_PKGS=(
  software-properties-common
  ca-certificates
  curl
  gns3-server
  dynagen
  dynamips
  vpcs
  python3
  python3-pip
  python3-setuptools
  qemu-kvm
  qemu-utils
)

readonly PKGS_OPENVPN=(openvpn uuid dnsutils)
readonly PKGS_WIREGUARD=(wireguard-tools)
readonly PKGS_DOCKER=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly PKGS_WELCOME=(net-tools dialog python3-dialog)

# ─── Option defaults ─────────────────────────────────────────────────────────

WITH_OPENVPN=0
WITH_WIREGUARD=0
WITH_DOCKER=1
WITH_WELCOME=0
DISABLE_KVM=0
DISABLE_FIREWALL=0
NO_SYSTEM_UPGRADE=0
REPOSITORY="ppa"

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
  cat >&2 <<EOF
${BOLD}gns3-remote-install-redux.sh${NC} — GNS3 remote server installer

${BOLD}Usage:${NC} sudo $0 [OPTIONS]

${BOLD}Options:${NC}
  --with-openvpn            Install and configure OpenVPN
  --with-wireguard          Install and configure WireGuard
  --with-welcome            Install GNS3-VM welcome.py console UI
  --without-kvm             Disable KVM hardware acceleration
  --without-docker          Skip Docker CE installation
  --without-firewall        Skip automatic UFW rule configuration
  --without-system-upgrade  Skip apt upgrade step
  --unstable                Use the GNS3 unstable PPA
  --custom-repository REPO  Use a custom GNS3 PPA name
  -h, --help                Show this help
EOF
}

# ─── Argument parsing ─────────────────────────────────────────────────────────

TEMP=$(getopt -o h --long with-openvpn,with-wireguard,with-welcome,without-kvm,without-docker,without-firewall,without-system-upgrade,unstable,custom-repository:,help -n "$0" -- "$@") || { show_help; exit 1; }
eval set -- "$TEMP"

while true; do
  case "$1" in
    --with-openvpn)           WITH_OPENVPN=1;        shift ;;
    --with-wireguard)         WITH_WIREGUARD=1;       shift ;;
    --with-welcome)           WITH_WELCOME=1;         shift ;;
    --without-kvm)            DISABLE_KVM=1;          shift ;;
    --without-docker)         WITH_DOCKER=0;          shift ;;
    --without-firewall)       DISABLE_FIREWALL=1;     shift ;;
    --without-system-upgrade) NO_SYSTEM_UPGRADE=1;    shift ;;
    --unstable)               REPOSITORY="unstable";  shift ;;
    --custom-repository)      REPOSITORY="$2";        shift 2 ;;
    -h|--help)                show_help; exit 0 ;;
    --)                       shift; break ;;
    *)                        log_fatal "Unknown option: $1" ;;
  esac
done

# ─── Roll up arrays based on flags ───────────────────────────────────────────

if [[ "$WITH_OPENVPN" -eq 1 ]]; then
  REQUIRED_PORTS+=(1194)
  REQUIRED_PKGS+=("${PKGS_OPENVPN[@]}")
fi

if [[ "$WITH_WIREGUARD" -eq 1 ]]; then
  REQUIRED_PORTS+=(51820)
  REQUIRED_MODS+=(wireguard)
  REQUIRED_PKGS+=("${PKGS_WIREGUARD[@]}")
fi

# Ephemeral config server needed if any VPN is enabled
if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
  REQUIRED_PORTS+=("$CONFIG_SERVE_PORT")
fi

if [[ "$WITH_DOCKER" -eq 1 ]]; then
  REQUIRED_PKGS+=("${PKGS_DOCKER[@]}")
  REQUIRED_GROUPS+=(docker)
fi

if [[ "$WITH_WELCOME" -eq 1 ]]; then
  REQUIRED_PKGS+=("${PKGS_WELCOME[@]}")
fi

# ─── Strict mode ON ──────────────────────────────────────────────────────────

set -euo pipefail
trap 'log_error "Script failed at line $LINENO. Partial install may need cleanup."' ERR

# ─── Preflight checks ────────────────────────────────────────────────────────

preflight_checks() {
  local has_errors=0

  # Hard stops — wrong OS or not root makes everything else meaningless
  if [[ "$EUID" -ne 0 ]]; then
    log_fatal "Must run as root. Try: sudo $0"
  fi

  if [[ ! "$OSTYPE" == linux-gnu* ]]; then
    log_fatal "This script requires Linux (detected: $OSTYPE)."
  fi

  # Source os-release early — we need it for the Ubuntu check and later for codename
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
  else
    log_fatal "/etc/os-release not found. Is this Ubuntu?"
  fi

  if [[ "${ID:-}" != "ubuntu" ]]; then
    log_fatal "This script requires Ubuntu (detected: ${ID:-unknown})."
  fi

  # Collect all remaining issues so the user gets them in one shot
  local missing_cmds=()
  for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" &>/dev/null || missing_cmds+=("$cmd")
  done
  if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    log_error "Missing commands: ${missing_cmds[*]}"
    has_errors=1
  fi

  local busy_ports=()
  for port in "${REQUIRED_PORTS[@]}"; do
    if ss -tlnH | grep -q ":${port} "; then
      busy_ports+=("$port")
    fi
  done
  if [[ ${#busy_ports[@]} -gt 0 ]]; then
    log_error "Port(s) already in use: ${busy_ports[*]}"
    has_errors=1
  fi

  local missing_mods=()
  for mod in "${REQUIRED_MODS[@]}"; do
    lsmod | grep -wq "$mod" 2>/dev/null || missing_mods+=("$mod")
  done
  if [[ ${#missing_mods[@]} -gt 0 ]]; then
    log_warn "Kernel module(s) not loaded: ${missing_mods[*]}  (may load on demand)"
  fi

  if [[ "$DISABLE_KVM" -eq 0 ]] && [[ $(grep -Ec '(vmx|svm)' /proc/cpuinfo) -eq 0 ]]; then
    log_warn "CPU virtualization extensions not detected. Pass --without-kvm if intentional."
  fi

  if [[ "$REPOSITORY" == "ppa-v3" ]]; then
    if ! python3 -c 'import sys; assert sys.version_info >= (3,9)' &>/dev/null; then
      log_error "GNS3 v3+ requires Python >= 3.9"
      has_errors=1
    fi
  fi

  if [[ "$has_errors" -eq 1 ]]; then
    log_fatal "Preflight failed. Fix the above and re-run."
  fi

  log_ok "Preflight checks passed"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Retry wrapper for apt — transient mirror failures happen
apt_retry() {
  local attempts=3 i
  for ((i = 1; i <= attempts; i++)); do
    if apt-get "$@"; then
      return 0
    fi
    log_warn "apt failed (attempt $i/$attempts), retrying in 5s..."
    sleep 5
  done
  log_fatal "apt failed after $attempts attempts: apt-get $*"
}

# Idempotent group creation
ensure_group() {
  getent group "$1" &>/dev/null || groupadd --system "$1"
}

# Detect the real human behind sudo
detect_invoking_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"
  fi
}

# Get public IP with fallback chain
get_public_ip() {
  curl -sf --max-time 5 https://icanhazip.com 2>/dev/null \
    || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo "UNKNOWN"
}

# Enable IPv4 forwarding (shared by both VPN types)
enable_ip_forwarding() {
  log_info "Enabling IPv4 forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  log_ok "IPv4 forwarding enabled (persistent)"
}

# ─── Ephemeral config file server ─────────────────────────────────────────────
# Serves VPN client configs via python3 http.server for CONFIG_SERVE_HOURS,
# then the systemd timer stops it automatically. Replaces nginx-light.

setup_config_server() {
  log_info "Setting up ephemeral config file server (port ${CONFIG_SERVE_PORT}, ${CONFIG_SERVE_HOURS}h TTL)..."

  # Create the serve directory with a UUID path segment so configs aren't guessable
  local serve_uuid
  serve_uuid=$(cat /proc/sys/kernel/random/uuid)
  local serve_path="${CONFIG_SERVE_DIR}/${serve_uuid}"
  mkdir -p "$serve_path"

  # Stash the UUID so the summary banner can reference it
  echo "$serve_uuid" > "${CONFIG_SERVE_DIR}/.serve_uuid"

  # Copy in whichever configs were generated
  if [[ "$WITH_OPENVPN" -eq 1 && -f /root/client.ovpn ]]; then
    cp /root/client.ovpn "${serve_path}/$(hostname).ovpn"
  fi
  if [[ "$WITH_WIREGUARD" -eq 1 && -f /etc/wireguard/client1.conf ]]; then
    cp /etc/wireguard/client1.conf "${serve_path}/wg-client1.conf"
  fi

  # Systemd service — python3 http.server
  cat > /lib/systemd/system/gns3-config-serve.service <<EOF
[Unit]
Description=GNS3 ephemeral VPN config server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${CONFIG_SERVE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${CONFIG_SERVE_PORT} --bind 0.0.0.0
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  # Systemd timer — auto-stop after CONFIG_SERVE_HOURS
  cat > /lib/systemd/system/gns3-config-serve-stop.timer <<EOF
[Unit]
Description=Stop GNS3 config server after ${CONFIG_SERVE_HOURS} hours

[Timer]
OnActiveSec=${CONFIG_SERVE_HOURS}h
AccuracySec=1min
Unit=gns3-config-serve-stop.service

[Install]
WantedBy=timers.target
EOF

  # Oneshot to stop + disable the server and clean up
  cat > /lib/systemd/system/gns3-config-serve-stop.service <<EOF
[Unit]
Description=Stop and clean up GNS3 config server

[Service]
Type=oneshot
ExecStart=/bin/systemctl stop gns3-config-serve.service
ExecStart=/bin/systemctl disable gns3-config-serve.service
ExecStart=/bin/rm -rf ${CONFIG_SERVE_DIR}
ExecStart=/bin/systemctl disable gns3-config-serve-stop.timer
EOF

  systemctl daemon-reload
  systemctl start gns3-config-serve.service
  systemctl enable --now gns3-config-serve-stop.timer

  log_ok "Config server live on port ${CONFIG_SERVE_PORT} (auto-stops in ${CONFIG_SERVE_HOURS}h)"

  # MOTD so it shows on next login
  local my_ip
  my_ip=$(get_public_ip)
  cat > /etc/update-motd.d/70-gns3-vpn <<EOFMOTD
#!/bin/sh
if systemctl is-active --quiet gns3-config-serve.service 2>/dev/null; then
  echo ""
  echo "────────────────────────────────────────────────────────────────────"
  echo "  VPN client configs: http://${my_ip}:${CONFIG_SERVE_PORT}/${serve_uuid}/"
  echo "  (server auto-expires — download configs now)"
  echo "────────────────────────────────────────────────────────────────────"
fi
EOFMOTD
  chmod 755 /etc/update-motd.d/70-gns3-vpn
}

# ─── Firewall (ufw) ──────────────────────────────────────────────────────────

configure_firewall() {
  if [[ "$DISABLE_FIREWALL" -eq 1 ]]; then
    log_info "Skipping firewall configuration (--without-firewall)"
    return
  fi

  # Check if ufw is present and active
  if ! command -v ufw &>/dev/null; then
    log_warn "No ufw detected. Ensure these ports are open in your firewall:"
    log_warn "  ${REQUIRED_PORTS[*]}"
    return
  fi

  if ! ufw status | grep -q "Status: active"; then
    log_warn "ufw is installed but inactive. Skipping rule creation."
    log_warn "  If you enable ufw later, allow ports: ${REQUIRED_PORTS[*]}"
    return
  fi

  log_info "Configuring ufw rules..."

  for port in "${REQUIRED_PORTS[@]}"; do
    ufw allow "$port"/tcp comment "GNS3 installer" >/dev/null 2>&1
    # Also allow UDP for VPN ports
    case "$port" in
      1194|51820)
        ufw allow "$port"/udp comment "GNS3 installer (VPN)" >/dev/null 2>&1
        ;;
    esac
  done

  # Enable forwarding in ufw if any VPN is configured
  if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
    local ufw_default="/etc/default/ufw"
    if [[ -f "$ufw_default" ]]; then
      if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$ufw_default"; then
        sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$ufw_default"
        log_info "Set UFW DEFAULT_FORWARD_POLICY=ACCEPT"
      fi
    fi
    ufw reload >/dev/null 2>&1
  fi

  log_ok "ufw rules applied for ports: ${REQUIRED_PORTS[*]}"
}

# ─── Core setup functions ────────────────────────────────────────────────────

setup_groups() {
  log_info "Creating required system groups..."
  for grp in "${REQUIRED_GROUPS[@]}"; do
    ensure_group "$grp"
  done
  log_ok "Groups: ${REQUIRED_GROUPS[*]}"
}

setup_gns3_user() {
  log_info "Setting up GNS3 service user..."
  mkdir -p "${GNS3_HOME}"/{images,projects,appliances,configs}

  if ! id "$GNS3_USER" &>/dev/null; then
    # Build comma-separated group list
    local groups_csv
    printf -v groups_csv '%s,' "${REQUIRED_GROUPS[@]}"
    groups_csv="${groups_csv%,}"

    useradd --system \
            --home-dir "$GNS3_HOME" \
            --no-create-home \
            --comment "GNS3 server" \
            --groups "$groups_csv" \
            --shell /usr/sbin/nologin \
            "$GNS3_USER"
    log_ok "Created user $GNS3_USER"
  else
    # User exists — make sure group membership is current
    for grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "$grp" "$GNS3_USER"
    done
    log_ok "User $GNS3_USER already exists — updated groups"
  fi

  chown -R "${GNS3_USER}:${GNS3_USER}" "$GNS3_HOME"
}

propagate_groups_to_invoker() {
  local invoker
  invoker=$(detect_invoking_user)
  if [[ -n "$invoker" ]]; then
    log_info "Adding $invoker to groups: ${REQUIRED_GROUPS[*]}"
    for grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "$grp" "$invoker"
    done
    log_ok "Group membership updated for $invoker (log out/in to take effect)"
  fi
}

add_gns3_repository() {
  log_info "Adding GNS3 PPA: ppa:gns3/$REPOSITORY"
  # -E preserves proxy env vars through sudo
  apt-add-repository -y "ppa:gns3/$REPOSITORY" >/dev/null
  log_ok "GNS3 repository added"
}

add_docker_repository() {
  log_info "Adding Docker CE repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "${DOCKER_BASE_URL}/gpg" -o "$DOCKER_KEYRING"
  chmod a+r "$DOCKER_KEYRING"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] ${DOCKER_BASE_URL} ${OS_CODENAME} stable
EOF
  log_ok "Docker repository added"
}

install_packages() {
  log_info "Updating package index..."
  apt_retry update -qq

  if [[ "$NO_SYSTEM_UPGRADE" -eq 0 ]]; then
    log_info "Upgrading system packages (this may take a while)..."
    apt_retry upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log_ok "System upgraded"
  else
    log_info "Skipping system upgrade (--without-system-upgrade)"
  fi

  log_info "Installing ${#REQUIRED_PKGS[@]} packages..."
  NEEDRESTART_MODE=a apt_retry install -y "${REQUIRED_PKGS[@]}"
  log_ok "All packages installed"
}

# ─── GNS3 server configuration ───────────────────────────────────────────────

configure_gns3() {
  log_info "Writing GNS3 server configuration..."

  local listen_host="0.0.0.0"
  # If OpenVPN is enabled, bind to the VPN interface only
  if [[ "$WITH_OPENVPN" -eq 1 ]]; then
    listen_host="172.16.253.1"
  fi

  local hw_accel="True"
  if [[ "$DISABLE_KVM" -eq 1 ]]; then
    hw_accel="False"
    log_warn "KVM disabled — Qemu performance will be degraded"
  fi

  mkdir -p "$GNS3_CONF_DIR"
  cat > "${GNS3_CONF_DIR}/gns3_server.conf" <<EOF
[Server]
host = ${listen_host}
port = 3080
images_path = ${GNS3_HOME}/images
projects_path = ${GNS3_HOME}/projects
appliances_path = ${GNS3_HOME}/appliances
configs_path = ${GNS3_HOME}/configs
report_errors = True

[Qemu]
enable_hardware_acceleration = ${hw_accel}
require_hardware_acceleration = ${hw_accel}
EOF

  chown -R "${GNS3_USER}:${GNS3_USER}" "$GNS3_CONF_DIR"
  chmod -R 700 "$GNS3_CONF_DIR"
  log_ok "GNS3 configuration written"
}

# ─── Systemd service ─────────────────────────────────────────────────────────

install_gns3_service() {
  log_info "Installing GNS3 systemd service..."

  # Use a heredoc with $MAINPID unexpanded (single-quoted delimiter)
  cat > "$GNS3_SERVICE_FILE" <<'EOF'
[Unit]
Description=GNS3 server
After=network-online.target
Wants=network-online.target
Conflicts=shutdown.target

[Service]
User=gns3
Group=gns3
PermissionsStartOnly=true
EnvironmentFile=/etc/environment
ExecStartPre=/bin/mkdir -p /var/log/gns3 /var/run/gns3
ExecStartPre=/bin/chown -R gns3:gns3 /var/log/gns3 /var/run/gns3
ExecStart=/usr/bin/gns3server --log /var/log/gns3/gns3.log
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$GNS3_SERVICE_FILE"
  chown root:root "$GNS3_SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable gns3
  log_ok "GNS3 service installed and enabled"
}

# ─── OpenVPN setup (ported from original) ─────────────────────────────────────

configure_openvpn() {
  log_info "Configuring OpenVPN..."

  local my_ip
  my_ip=$(dig @ns1.google.com -t txt o-o.myaddr.l.google.com +short -4 2>/dev/null | sed 's/"//g')
  if [[ -z "$my_ip" ]]; then
    my_ip=$(get_public_ip)
  fi
  log_info "Public IP detected: $my_ip"

  local ovpn_uuid
  ovpn_uuid=$(uuid)
  local hostname
  hostname=$(hostname)

  # TUN device
  [[ -d /dev/net ]] || mkdir -p /dev/net
  [[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200

  # Generate keys idempotently
  log_info "Generating OpenVPN keys (DH params may take a minute)..."
  mkdir -p /etc/openvpn
  [[ -f /etc/openvpn/dh.pem ]]   || openssl dhparam -out /etc/openvpn/dh.pem 2048
  [[ -f /etc/openvpn/key.pem ]]  || openssl genrsa -out /etc/openvpn/key.pem 2048
  chmod 600 /etc/openvpn/key.pem
  [[ -f /etc/openvpn/csr.pem ]]  || openssl req -new -key /etc/openvpn/key.pem -out /etc/openvpn/csr.pem -subj /CN=OpenVPN/
  [[ -f /etc/openvpn/cert.pem ]] || openssl x509 -req -in /etc/openvpn/csr.pem -out /etc/openvpn/cert.pem -signkey /etc/openvpn/key.pem -days 3650

  # Client config
  cat > /root/client.ovpn <<EOFCLIENT
client
nobind
comp-lzo
dev tun
<key>
$(cat /etc/openvpn/key.pem)
</key>
<cert>
$(cat /etc/openvpn/cert.pem)
</cert>
<ca>
$(cat /etc/openvpn/cert.pem)
</ca>
<dh>
$(cat /etc/openvpn/dh.pem)
</dh>
<connection>
remote ${my_ip} 1194 udp
</connection>
EOFCLIENT

  # Server config
  cat > /etc/openvpn/udp1194.conf <<EOFUDP
server 172.16.253.0 255.255.255.0
verb 3
duplicate-cn
comp-lzo
key key.pem
ca cert.pem
cert cert.pem
dh dh.pem
keepalive 10 60
persist-key
persist-tun
proto udp
port 1194
dev tun1194
status openvpn-status-1194.log
log-append /var/log/openvpn-udp1194.log
EOFUDP

  # Start OpenVPN
  systemctl restart openvpn || true   # may fail first run before reboot

  log_ok "OpenVPN configured"
}

# ─── WireGuard setup (new) ────────────────────────────────────────────────────

configure_wireguard() {
  log_info "Configuring WireGuard..."

  local my_ip
  my_ip=$(get_public_ip)

  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard

  # Generate server keys idempotently
  if [[ ! -f /etc/wireguard/server.key ]]; then
    wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
    chmod 600 /etc/wireguard/server.key
  fi

  local server_privkey server_pubkey
  server_privkey=$(cat /etc/wireguard/server.key)
  server_pubkey=$(cat /etc/wireguard/server.pub)

  # Generate a first client keypair for convenience
  if [[ ! -f /etc/wireguard/client1.key ]]; then
    wg genkey | tee /etc/wireguard/client1.key | wg pubkey > /etc/wireguard/client1.pub
    chmod 600 /etc/wireguard/client1.key
  fi

  local client_privkey client_pubkey
  client_privkey=$(cat /etc/wireguard/client1.key)
  client_pubkey=$(cat /etc/wireguard/client1.pub)

  # Server interface config
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 172.16.254.1/24
ListenPort = 51820
PrivateKey = ${server_privkey}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# client1
PublicKey = ${client_pubkey}
AllowedIPs = 172.16.254.2/32
EOF

  chmod 600 /etc/wireguard/wg0.conf

  # Client config for easy download
  cat > /etc/wireguard/client1.conf <<EOF
[Interface]
Address = 172.16.254.2/24
PrivateKey = ${client_privkey}
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${my_ip}:51820
AllowedIPs = 172.16.253.0/24, 172.16.254.0/24
PersistentKeepalive = 25
EOF

  systemctl enable wg-quick@wg0
  systemctl start wg-quick@wg0 || true

  log_ok "WireGuard configured"
}

# ─── Welcome setup (ported from original) ─────────────────────────────────────

configure_welcome() {
  log_info "Setting up GNS3-VM welcome console..."

  cat > /etc/sudoers.d/gns3 <<EOF
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-key
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-get
gns3   ALL = (ALL) NOPASSWD: /usr/sbin/reboot
EOF
  chmod 440 /etc/sudoers.d/gns3

  curl -fsSL https://raw.githubusercontent.com/GNS3/gns3-server/master/scripts/welcome.py \
    -o /usr/local/bin/welcome.py
  chmod 755 /usr/local/bin/welcome.py
  chown "${GNS3_USER}:${GNS3_USER}" /usr/local/bin/welcome.py

  # Auto-login gns3 on tty1
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a gns3 --noclear %I $TERM
EOF
  chmod 644 /etc/systemd/system/getty@tty1.service.d/override.conf

  # Launch welcome on login
  grep -q 'welcome.py' "${GNS3_HOME}/.bashrc" 2>/dev/null || \
    echo "python3 /usr/local/bin/welcome.py" >> "${GNS3_HOME}/.bashrc"

  echo "gns3:gns3" | chpasswd
  usermod --shell /bin/bash "$GNS3_USER"
  usermod -aG sudo "$GNS3_USER"

  log_ok "Welcome console configured"
}

# ─── Start services ──────────────────────────────────────────────────────────

start_services() {
  log_info "Starting GNS3 service..."
  systemctl restart gns3
  log_ok "GNS3 service running"

  if [[ "$WITH_DOCKER" -eq 1 ]]; then
    systemctl enable docker
    systemctl start docker
    log_ok "Docker service running"
  fi
}

# ─── Summary banner ──────────────────────────────────────────────────────────

print_summary() {
  local my_ip
  my_ip=$(get_public_ip)

  echo ""
  printf "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              GNS3 Server Installation Complete              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  printf "${NC}"
  echo ""
  echo "  GNS3 Server:  http://${my_ip}:3080"
  echo "  Config:       ${GNS3_CONF_DIR}/gns3_server.conf"
  echo "  Data:         ${GNS3_HOME}/"
  echo "  Logs:         /var/log/gns3/gns3.log"
  echo "  Service:      systemctl status gns3"
  echo ""

  # Show config server URL if VPN configs are being served
  if [[ -f "${CONFIG_SERVE_DIR}/.serve_uuid" ]]; then
    local serve_uuid
    serve_uuid=$(cat "${CONFIG_SERVE_DIR}/.serve_uuid")
    echo "  ┌─ VPN Client Configs ──────────────────────────────────────"
    echo "  │  http://${my_ip}:${CONFIG_SERVE_PORT}/${serve_uuid}/"
    if [[ "$WITH_OPENVPN" -eq 1 ]]; then
      echo "  │    └─ $(hostname).ovpn"
    fi
    if [[ "$WITH_WIREGUARD" -eq 1 ]]; then
      echo "  │    └─ wg-client1.conf"
    fi
    printf "  │  ${YELLOW}Server auto-expires in ${CONFIG_SERVE_HOURS}h — download configs now${NC}\n"
    echo "  └─────────────────────────────────────────────────────────"
    echo ""
  fi

  if [[ "$DISABLE_KVM" -eq 1 ]]; then
    printf "  ${YELLOW}KVM:          DISABLED (--without-kvm)${NC}\n"
  fi

  local invoker
  invoker=$(detect_invoking_user)
  if [[ -n "$invoker" ]]; then
    echo ""
    printf "  ${CYAN}Note:${NC} Log out and back in as ${BOLD}${invoker}${NC} for group changes to take effect.\n"
  fi

  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN — guarded so `source` loads functions without executing.
# Run directly: ./script.sh       → executes main
# Source:       source script.sh   → functions only (for BATS testing)
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  export DEBIAN_FRONTEND="noninteractive"

  preflight_checks

  # OS metadata (available after preflight sources /etc/os-release)
  readonly OS_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

  # ── Phase 1: Repositories ──────────────────────────────────────────────────

  add_gns3_repository
  if [[ "$WITH_DOCKER" -eq 1 ]]; then add_docker_repository; fi

  # ── Phase 2: Packages (single apt pass) ────────────────────────────────────

  install_packages

  # ── Phase 3: Users and groups ──────────────────────────────────────────────

  setup_groups
  setup_gns3_user
  propagate_groups_to_invoker

  # ── Phase 4: Configuration ─────────────────────────────────────────────────

  configure_gns3
  install_gns3_service

  if [[ "$WITH_OPENVPN" -eq 1 ]];   then configure_openvpn; fi
  if [[ "$WITH_WIREGUARD" -eq 1 ]]; then configure_wireguard; fi
  if [[ "$WITH_WELCOME" -eq 1 ]];   then configure_welcome; fi

  # Shared VPN plumbing
  if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
    enable_ip_forwarding
    setup_config_server
  fi

  # Firewall
  configure_firewall

  # ── Phase 5: Start ─────────────────────────────────────────────────────────

  start_services

  # ── Phase 6: Welcome post-install repair (matches original behavior) ───────

  if [[ "$WITH_WELCOME" -eq 1 ]]; then
    python3 -c 'import sys; sys.path.append("/usr/local/bin/"); import welcome; ws = welcome.Welcome_dialog(); ws.repair_remote_install()' || true
  fi

  # ── Done ───────────────────────────────────────────────────────────────────

  print_summary
}

# Only run main when executed directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
