#!/usr/bin/env bash

# ### gns3-remote-install.sh ###################################################

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
#   --unsafe-configs          Serve VPN configs unencrypted (not recommended)
#   --unstable                Use GNS3 unstable PPA
#   --custom-repository REPO  Use a custom GNS3 PPA name
#   -h, --help                Show this help

### To Me ################################################################

# Dear Shane, please review this note to Shane. Love, Shane.
#
# Variables:
#   Global readonly constants:   ROARING_SNEK_CASE
#   Mutable globals:             ROARING_SNEK_CASE (mut_ROAR?)
#   Function-local variables:    _snake_case (prefix)
#   Loop iterators:              _snake_case (also prefix - add suffix  _snek_?)
#   Variable expansion:          "${VAR}" not "$VAR" - quote and brace
#
# Functions:
#   Names are lowercase_snake_case
#   Each function starts with a `local` declaration block for all locals
#   Return 0 - success, 1 - "handled failure", log_fatal - "can't proceed"
#
# File writes:
#   ensure_config for anything that needs specific perms
#   ensure_directory before writing to a new path
#   require_file after any external process that should produce a file
#
# Logging:
#   log_info(): what we're about to do (or did, non-critical)
#   log_ok():   confirmation that something worked
#   log_warn(): non-fatal issue, not actionable
#   log_warn_sticky(): non-fatal but user needs to know at summary time
#   log_error(): something failed but we're continuing
#   log_fatal(): cannot proceed; exits
#
# Services: use enable_and_start() - not systemctl enable/start/restart
# External resources: use fetch_resource() with ordered fallbacks (local → canonical → mirror)
#
# Idempotency:
#   Every function should be safe to re-run
#   Key writes: [[ -f key ]] || generate (never overwrite existing keys)
#   Config writes: always overwrite existing configs
#   Groups/users: ensure_group / id checks

### Constants ################################################################

readonly REPO_BASE_URL="https://raw.githubusercontent.com/lark-cx/gns3-server-deploy/refs/heads/main/"
readonly REPO_LANDING_HTML="template.html"
readonly REPO_DOCKER_GPG="docker-gpg"
readonly DOCKER_BASE_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly GNS3_USER="gns3"
readonly GNS3_HOME="/opt/gns3"
readonly GNS3_CONF_DIR="/etc/gns3"
readonly GNS3_PORT=3080
readonly GNS3_SERVICE_FILE="/lib/systemd/system/gns3.service"
readonly GNS3_VENV="/usr/share/gns3/gns3-server"
readonly CONFIG_SERVE_PORT=8003
readonly CONFIG_SERVE_DIR="/var/lib/gns3-config-serve"
readonly CONFIG_SERVE_HOURS=2
readonly DEPLOY_MARKER="# deployed by gns3-remote-install-redux"
readonly DEPLOY_DIR="/root/.gns3-deploy"

### VPN Constants #############################################################
readonly OVPN_CONF_DIR="/etc/openvpn"
readonly OVPN_PORT=1194
readonly WG_CONF_DIR="/etc/wireguard"
readonly WG_PORT=51820

### Colors ####################################################################
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

### Logging ##################################################################
log_info() { printf "${CYAN}[INFO]${NC}  %s\n" "$1" >&2; }
log_ok() { printf "${GREEN}[ OK ]${NC}  %s\n" "$1" >&2; }
log_warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$1" >&2; }
log_error() { printf "${RED}[FAIL]${NC}  %s\n" "$1" >&2; }
log_fatal() {
  printf "${RED}[FATAL]${NC} %s\n" "$1" >&2
  exit 1
}

# Testability wrapper — EUID is readonly in bash, so tests override this function
is_root() { [[ ${EUID} -eq 0 ]]; }

# Sticky warnings — collected throughout execution, displayed before summary
WARNINGS=()
log_warn_sticky() {
  log_warn "$1"
  WARNINGS+=("$1")
}

### Mutable arrays (built up by option flags) ##############################─
REQUIRED_CMDS=(apt apt-add-repository dpkg chown chmod useradd usermod lsmod systemctl ss openssl)
REQUIRED_PORTS=($GNS3_PORT)
REQUIRED_GROUPS=(kvm ubridge)
REQUIRED_MODS=(kvm)

REQUIRED_PKGS=(
  software-properties-common
  ca-certificates
  curl
  gns3-server
  dynamips
  vpcs
  python3
  python3-pip
  python3-setuptools
  qemu-system-x86
  qemu-utils
)

readonly PKGS_OPENVPN=(openvpn dnsutils)
readonly PKGS_WIREGUARD=(wireguard-tools)
readonly PKGS_DOCKER=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly PKGS_WELCOME=(net-tools dialog python3-dialog)

### Option defaults ##########################################################

WITH_OPENVPN=0
WITH_WIREGUARD=0
WITH_DOCKER=1
WITH_WELCOME=0
DISABLE_KVM=0
DISABLE_FIREWALL=0
NO_SYSTEM_UPGRADE=0
UNSAFE_CONFIGS=0
USE_LEGACY_RSA=0
REPOSITORY="ppa"

### Help ####################################################################─

show_help() {
cat >&2 <<_EOF_HELP
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
  --unsafe-configs          Serve VPN configs unencrypted
  --unstable                Use the GNS3 unstable PPA
  --custom-repository REPO  Use a custom GNS3 PPA name
  -h, --help                Show this help
_EOF_HELP
}

### Argument parsing ##########################################################

TEMP=$(getopt -o h --long with-openvpn,with-wireguard,with-welcome,without-kvm,without-docker,without-firewall,without-system-upgrade,unsafe-configs,legacy-rsa,unstable,custom-repository:,help -n "$0" -- "$@") || {
  show_help
  exit 1
}
eval set -- "${TEMP}"

while true; do
  case "$1" in
  --with-openvpn)
    WITH_OPENVPN=1
    shift
    ;;
  --with-wireguard)
    WITH_WIREGUARD=1
    shift
    ;;
  --with-welcome)
    WITH_WELCOME=1
    shift
    ;;
  --without-kvm)
    DISABLE_KVM=1
    shift
    ;;
  --without-docker)
    WITH_DOCKER=0
    shift
    ;;
  --without-firewall)
    DISABLE_FIREWALL=1
    shift
    ;;
  --without-system-upgrade)
    NO_SYSTEM_UPGRADE=1
    shift
    ;;
  --unsafe-configs)
    UNSAFE_CONFIGS=1
    shift
    ;;
  --legacy-rsa)
    USE_LEGACY_RSA=1
    shift
    ;;
  --unstable)
    REPOSITORY="unstable"
    shift
    ;;
  --custom-repository)
    REPOSITORY="$2"
    shift 2
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *) log_fatal "Unknown option: $1" ;;
  esac
done

### Roll up arrays based on flags ##########################################─

if [[ ${WITH_OPENVPN} -eq 1 ]]; then
  REQUIRED_PORTS+=($OVPN_PORT)
  REQUIRED_PKGS+=("${PKGS_OPENVPN[@]}")
fi

if [[ ${WITH_WIREGUARD} -eq 1 ]]; then
  REQUIRED_PORTS+=($WG_PORT)
  REQUIRED_MODS+=(wireguard)
  REQUIRED_PKGS+=("${PKGS_WIREGUARD[@]}")
fi

# Config server port always needed (landing page is default-on)
REQUIRED_PORTS+=("${CONFIG_SERVE_PORT}")

if [[ ${WITH_DOCKER} -eq 1 ]]; then
  REQUIRED_PKGS+=("${PKGS_DOCKER[@]}")
  REQUIRED_GROUPS+=(docker)
fi

if [[ ${WITH_WELCOME} -eq 1 ]]; then
  REQUIRED_PKGS+=("${PKGS_WELCOME[@]}")
fi

### Preflight checks ########################################################

preflight_checks() {
  local _has_errors=0

  if [[ ${OSTYPE} != linux-gnu* ]]; then
    log_fatal "This script requires Linux (detected: ${OSTYPE})."
  fi

  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
  else
    log_fatal "/etc/os-release not found. Is this Ubuntu?"
  fi

  if [[ ${ID:-} != "ubuntu" ]]; then
    log_fatal "This script requires Ubuntu (detected: ${ID:-unknown})."
  fi

  local -a _missing_cmds=()
  for _cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "${_cmd}" &>/dev/null || _missing_cmds+=("${_cmd}")
  done
  if [[ ${#_missing_cmds[@]} -gt 0 ]]; then
    log_error "Missing commands: ${_missing_cmds[*]}"
    _has_errors=1
  fi

  # Detect reconfigure: our config marker + gns3 service running
  if [[ -f "${GNS3_CONF_DIR}/gns3_server.conf" ]] &&
    grep -q "${DEPLOY_MARKER}" "${GNS3_CONF_DIR}/gns3_server.conf" 2>/dev/null &&
    systemctl is-active --quiet gns3 2>/dev/null; then
    log_info "Existing installation detected — running in reconfigure mode"
    systemctl stop gns3
    systemctl stop gns3-config-serve.service 2>/dev/null || true
  fi

  local -a _busy_ports=()
  for _port in "${REQUIRED_PORTS[@]}"; do
    if ss -tlnH | grep -q ":${_port} "; then
      _busy_ports+=("${_port}")
    fi
  done
  if [[ ${#_busy_ports[@]} -gt 0 ]]; then
    log_error "Port(s) already in use: ${_busy_ports[*]}"
    _has_errors=1
  fi

  # Ensure time synchronization is active for VPN certificate validity
  if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true || log_warn_sticky "Could not enable NTP. Ensure server time is correct for VPN certs."
  fi

  # Load missing kernel modules automatically unless --without-kvm
  local -a _missing_mods=()
  for _mod in "${REQUIRED_MODS[@]}"; do
    if ! lsmod | grep -wq "${_mod}" 2>/dev/null; then
      if [[ ${_mod} == "kvm" && ${DISABLE_KVM} -eq 1 ]]; then
        continue
      fi
      log_info "Loading kernel module: ${_mod}"
      if modprobe "${_mod}" 2>/dev/null; then
        log_ok "Loaded ${_mod}"
        if ! grep -qx "${_mod}" /etc/modules-load.d/gns3.conf 2>/dev/null; then
          echo "${_mod}" >>/etc/modules-load.d/gns3.conf
        fi
      else
        _missing_mods+=("${_mod}")
      fi
    fi
  done
  if [[ ${#_missing_mods[@]} -gt 0 ]]; then
    log_warn_sticky "Kernel module(s) could not be loaded: ${_missing_mods[*]}"
    log_warn_sticky "  Manual fix: modprobe ${_missing_mods[*]}"
  fi

  if [[ ${DISABLE_KVM} -eq 0 ]] && [[ $(grep -Ec '(vmx|svm)' /proc/cpuinfo) -eq 0 ]]; then
    log_warn_sticky "CPU virtualization extensions not detected. KVM will not function."
    log_warn_sticky "  If running in a VM without nested virt, pass --without-kvm"
  fi

  if [[ ${REPOSITORY} == "ppa-v3" ]]; then
    if ! python3 -c 'import sys; assert sys.version_info >= (3,9)' &>/dev/null; then
      log_error "GNS3 v3+ requires Python >= 3.9"
      _has_errors=1
    fi
  fi

  if [[ ${_has_errors} -eq 1 ]]; then
    log_fatal "Preflight failed. Fix the above and re-run."
  fi

  log_ok "Preflight checks passed"
}

### Helpers ##################################################################

apt_retry() {
  local _attempts=3 _i _apt_log
  _apt_log=$(mktemp)
  for ((_i = 1; _i <= _attempts; _i++)); do
    if apt-get "$@" -qq >"${_apt_log}" 2>&1; then
      rm -f "${_apt_log}"
      return 0
    fi
    log_warn "apt failed (attempt ${_i}/${_attempts}), retrying in 5s..."
    tail -5 "${_apt_log}" >&2
    sleep 5
  done
  log_error "apt output:"
  tail -10 "${_apt_log}" >&2
  rm -f "${_apt_log}"
  log_fatal "apt failed after ${_attempts} attempts: apt-get $*"
}

ensure_group() {
  getent group "$1" &>/dev/null || groupadd --system "$1"
}

detect_invoking_user() {
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
    echo "${SUDO_USER}"
  fi
}

# Get public IP with fallback chain (dig → curl → UNKNOWN)
get_public_ip() {
  local _ip
  _ip=$(dig @ns1.google.com -t txt o-o.myaddr.l.google.com +short -4 2>/dev/null | sed 's/"//g')
  if [[ -n ${_ip} ]]; then
    echo "${_ip}"
    return
  fi
  _ip=$(curl -sf --max-time 5 https://icanhazip.com 2>/dev/null)
  if [[ -n ${_ip} ]]; then
    echo "${_ip}"
    return
  fi
  _ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)
  if [[ -n ${_ip} ]]; then
    echo "${_ip}"
    return
  fi
  echo "UNKNOWN"
}

# Get LAN IP — primary interface address
get_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

# Generate a readable one-time passphrase: XXXX-XXXX-####
generate_passphrase() {
  local _hex
  _hex=$(openssl rand -hex 4)
  printf "%s-%s" "${_hex:0:4}" "${_hex:4:4}" | tr 'a-f' 'A-F'
}

# Encrypt a file with a passphrase, output .enc alongside original
encrypted_copy() {
  local _src="$1" _dst="$2" _pass="$3"
  openssl aes-256-cbc -pbkdf2 -iter 10000 -pass "pass:${_pass}" -a -in "${_src}" -out "${_dst}"
}

enable_ip_forwarding() {
  log_info "Enabling IPv4 forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf
  fi
  log_ok "IPv4 forwarding enabled (persistent)"
}

# Apply baseline sysctl hardening — safe, standard CIS recommendations
apply_sysctl_hardening() {
  log_info "Applying sysctl hardening..."

  local -A _sysctls=(
    ["net.ipv4.conf.all.rp_filter"]="2"
    ["net.ipv4.conf.default.rp_filter"]="2"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.default.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv4.conf.default.send_redirects"]="0"
    ["net.ipv4.conf.all.accept_source_route"]="0"
    ["net.ipv4.conf.default.accept_source_route"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["net.ipv6.conf.default.accept_redirects"]="0"
  )

  local _sysctl_file="/etc/sysctl.d/90-gns3-hardening.conf"
  : >"${_sysctl_file}"

  for _key in "${!_sysctls[@]}"; do
    local _val="${_sysctls[$_key]}"
    echo "${_key}=${_val}" >>"${_sysctl_file}"
    sysctl -w "${_key}=${_val}" >/dev/null 2>&1
  done

  log_ok "Sysctl hardening applied (${_sysctl_file})"
}

# Safe and quiet service (re)start - with mulligan
enable_and_start() {
  local _svc="$1"
  systemctl daemon-reload &>/dev/null
  systemctl enable "${_svc}" &>/dev/null 2>&1
  systemctl restart "${_svc}" ||
    {
      sleep 3
      systemctl start "${_svc}"
    } ||
    true
}

# Verify a file exists and is non-empty. Returns 1 and logs sticky warning on failure.
require_file() {
  local _path="$1" _desc="${2:-file}"
  if [[ ! -s ${_path} ]]; then
    log_warn_sticky "${_desc} missing or empty: ${_path}"
    return 1
  fi
  return 0
}

# Idempotent directory creation with ownership and mode. Creates if missing,
# applies chown/chmod either way (in case perms drifted).
ensure_directory() {
  local _path="$1" _owner="${2:-root}" _mode="${3:-}"
  if [[ -d ${_path} ]]; then
    log_info "Directory exists: ${_path}"
  else
    mkdir -p "${_path}"
    log_info "Created directory: ${_path}"
  fi
  chown "${_owner}:${_owner}" "${_path}"
  [[ -n ${_mode} ]] && chmod "${_mode}" "${_path}"
}

# Atomically write a config file with the right perms from the start.
# Reads content from stdin. Writes to tempfile in target dir, sets perms,
# then renames — the final path never exists with open perms, even briefly.
#
# Usage:
#   ensure_config /etc/wireguard/wg0.conf root 600 <<EOF
#   [Interface]
#   ...
#   EOF
#
#   openssl ecparam -name secp384r1 -genkey -noout | \
#     ensure_config /etc/openvpn/key.pem root 600
ensure_config() {
  local _path="$1" _owner="${2:-root}" _mode="${3:-644}"
  local _dir _tmp
  _dir="$(dirname "${_path}")"

  # Make sure destination directory exists (don't override caller's perms on it)
  [[ -d ${_dir} ]] || mkdir -p "${_dir}"

  # Temp file in same directory so mv is atomic (same filesystem)
  _tmp=$(mktemp "${_path}.XXXXXX")

  # Restrictive umask during write — file never exists with open perms
  (umask 077 && cat >"${_tmp}")

  chown "${_owner}:${_owner}" "${_tmp}"
  chmod "${_mode}" "${_tmp}"
  mv "${_tmp}" "${_path}"

  # Self-verify: confirm the file actually made it and is non-empty
  require_file "${_path}" "config" || return 1
  log_info "Wrote config: ${_path} (mode ${_mode}, owner ${_owner})"
}

# Try sequential sources until one succeeds. First arg is destination,
# remaining args are sources tried in order. Local paths detected by absence
# of http(s):// prefix. Returns 1 if all sources fail.
#
# Usage:
#   fetch_resource /etc/apt/keyrings/docker.asc \
#     "${_script_dir}/docker-gpg" \
#     "https://download.docker.com/linux/ubuntu/gpg" \
#     "${REPO_BASE_URL}docker-gpg"
fetch_resource() {
  local _dst="$1"
  shift
  local _src
  for _src in "$@"; do
    if [[ ${_src} =~ ^https?:// ]]; then
      if curl -fsSL --max-time 10 "${_src}" -o "${_dst}" 2>/dev/null; then
        log_info "Fetched from remote: ${_src}"
        return 0
      fi
      log_warn "Remote fetch failed: ${_src}"
    elif [[ -f ${_src} ]]; then
      if cp "${_src}" "${_dst}" 2>/dev/null; then
        log_info "Copied from local: ${_src}"
        return 0
      fi
      log_warn "Local copy failed: ${_src}"
    fi
  done
  log_warn_sticky "All sources failed for: ${_dst}"
  return 1
}

### Ephemeral config file server ##############################################

setup_config_server() {
  log_info "Setting up config server (port ${CONFIG_SERVE_PORT}, ${CONFIG_SERVE_HOURS}h TTL)..."

  # Stop existing server if running from a previous install
  if systemctl is-active --quiet gns3-config-serve.service 2>/dev/null; then
    systemctl stop gns3-config-serve.service 2>/dev/null || true
    systemctl stop gns3-config-serve-stop.timer 2>/dev/null || true
    log_info "Stopped previous config server"
  fi

  # Clean previous serve directory (public-facing only)
  [[ -d ${CONFIG_SERVE_DIR} ]] && rm -rf "${CONFIG_SERVE_DIR}"

  # Ensure deploy directory exists for secrets
  mkdir -p "${DEPLOY_DIR}"
  chmod 700 "${DEPLOY_DIR}"

  # Persist slug across re-runs so URL stays stable
  local _serve_slug
  if [[ -f "${DEPLOY_DIR}/serve_slug" ]]; then
    _serve_slug=$(cat "${DEPLOY_DIR}/serve_slug")
    log_info "Reusing existing serve slug: ${_serve_slug}"
  else
    _serve_slug=$(openssl rand -hex 3)
    echo "${_serve_slug}" >"${DEPLOY_DIR}/serve_slug"
    chmod 600 "${DEPLOY_DIR}/serve_slug"
  fi

  local _serve_path="${CONFIG_SERVE_DIR}/${_serve_slug}"
  mkdir -p "${_serve_path}"
  log_info "Config serve path: ${_serve_path}"

  local _lan_ip _public_ip _gns3_bin _gns3_ver
  _lan_ip=$(get_lan_ip)
  _public_ip=$(get_public_ip)
  _gns3_bin="/usr/bin/gns3server"
  [[ -x "${GNS3_VENV}/bin/gns3server" ]] && _gns3_bin="${GNS3_VENV}/bin/gns3server"

  # Extract exact semantic version, fallback to "unknown"
  _gns3_ver=$("${_gns3_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
  [[ -z ${_gns3_ver} ]] && _gns3_ver="unknown"

  # ## VPN config files (encrypted by default) ################################
  local _conf_passphrase=""

  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    # Fatal if we can't determine public IP for VPN configs
    if [[ ${_public_ip} == "UNKNOWN" ]]; then
      log_fatal "Could not determine public IP — VPN configs require a reachable address."
    fi

    if [[ ${UNSAFE_CONFIGS} -eq 0 ]]; then
      # Persist passphrase across re-runs
      if [[ -f "${DEPLOY_DIR}/passphrase" ]]; then
        _conf_passphrase=$(cat "${DEPLOY_DIR}/passphrase")
        log_info "Reusing existing config passphrase"
      else
        _conf_passphrase=$(generate_passphrase)
        echo "${_conf_passphrase}" >"${DEPLOY_DIR}/passphrase"
        chmod 600 "${DEPLOY_DIR}/passphrase"
      fi
    fi
  fi

  if [[ ${WITH_OPENVPN} -eq 1 && -f /root/client.ovpn ]]; then
    if [[ ${UNSAFE_CONFIGS} -eq 1 ]]; then
      cp /root/client.ovpn "${_serve_path}/o"
    else
      encrypted_copy /root/client.ovpn "${_serve_path}/o" "${_conf_passphrase}"
    fi
  fi

  if [[ ${WITH_WIREGUARD} -eq 1 && -f "${WG_CONF_DIR}/client1.conf" ]]; then
    if [[ ${UNSAFE_CONFIGS} -eq 1 ]]; then
      cp "${WG_CONF_DIR}/client1.conf" "${_serve_path}/w"
    else
      encrypted_copy "${WG_CONF_DIR}/client1.conf" "${_serve_path}/w" "${_conf_passphrase}"
    fi
  fi

  # Also stash client configs in deploy dir for safekeeping
  [[ -f /root/client.ovpn ]] && cp /root/client.ovpn "${DEPLOY_DIR}/client.ovpn"
  [[ -f "${WG_CONF_DIR}/client1.conf" ]] && cp "${WG_CONF_DIR}/client1.conf" "${DEPLOY_DIR}/wg-client1.conf"

  # ## Landing page ##########################################################

  log_info "Fetching UI template..."

  local _script_dir _template_src _template_dst _template_ok
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  _template_src="${_script_dir}/${REPO_LANDING_HTML}"
  _template_dst="${CONFIG_SERVE_DIR}/index.html"
  _template_ok=0

  if fetch_resource "${_template_dst}" \
    "${_template_src}" \
    "${REPO_BASE_URL}${REPO_LANDING_HTML}"; then
    _template_ok=1
  else
    log_error "Failed to obtain template. Using basic fallback UI."
    echo "<html><body><h1>GNS3 Config Server</h1><p>Template missing. Check server terminal for config details.</p></body></html>" >"${_template_dst}"
  fi

  # Only run sed injections if we got the template (from either local or curl)
  if [[ ${_template_ok} -eq 1 ]]; then
    log_info "Injecting server data into UI template..."

    # Build warnings JSON array for injection
    local _warnings_json="[]"
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
      _warnings_json="["
      for _w in "${WARNINGS[@]}"; do
        _warnings_json+="\"$(echo "${_w}" | sed 's/"/\\"/g')\","
      done
      _warnings_json="${_warnings_json%,}]"
    fi

    # Use | as the sed delimiter to avoid conflicts with slashes in URLs/paths
    sed -i "s|{{LAN_IP}}|${_lan_ip}|g" "${_template_dst}"
    sed -i "s|{{PUBLIC_IP}}|${_public_ip}|g" "${_template_dst}"
    sed -i "s|{{HOSTNAME}}|$(hostname)|g" "${_template_dst}"
    sed -i "s|{{GNS3_VERSION}}|${_gns3_ver}|g" "${_template_dst}"
    sed -i "s|{{GNS3_PORT}}|${GNS3_PORT}|g" "${_template_dst}"
    sed -i "s|{{WITH_OPENVPN}}|${WITH_OPENVPN}|g" "${_template_dst}"
    sed -i "s|{{WITH_WIREGUARD}}|${WITH_WIREGUARD}|g" "${_template_dst}"
    sed -i "s|{{WITH_DOCKER}}|${WITH_DOCKER}|g" "${_template_dst}"
    sed -i "s|{{DISABLE_KVM}}|${DISABLE_KVM}|g" "${_template_dst}"
    sed -i "s|{{UNSAFE_CONFIGS}}|${UNSAFE_CONFIGS}|g" "${_template_dst}"
    sed -i "s|{{SERVE_SLUG}}|${_serve_slug}|g" "${_template_dst}"
    sed -i "s|{{SERVE_HOURS}}|${CONFIG_SERVE_HOURS}|g" "${_template_dst}"
    sed -i "s|{{SERVE_PORT}}|${CONFIG_SERVE_PORT}|g" "${_template_dst}"
    sed -i "s|{{WARNINGS_JSON}}|${_warnings_json}|g" "${_template_dst}"
    sed -i "s|{{OVPN_PORT}}|${OVPN_PORT}|g" "${_template_dst}"
    sed -i "s|{{WG_PORT}}|${WG_PORT}|g" "${_template_dst}"

    log_ok "Landing page generated"
  fi

  # ## Systemd units ##########################################################

  ensure_config /lib/systemd/system/gns3-config-serve.service root 644 <<_EOF_HTTP_SVC
[Unit]
Description=GNS3 ephemeral config server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${CONFIG_SERVE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${CONFIG_SERVE_PORT} --bind 0.0.0.0
Restart=no

[Install]
WantedBy=multi-user.target
_EOF_HTTP_SVC

  ensure_config /lib/systemd/system/gns3-config-serve-stop.timer root 644 <<_EOF_CONF_TMR
[Unit]
Description=Stop GNS3 config server after ${CONFIG_SERVE_HOURS} hours

[Timer]
OnActiveSec=${CONFIG_SERVE_HOURS}h
AccuracySec=1min
Unit=gns3-config-serve-stop.service

[Install]
WantedBy=timers.target
_EOF_CONF_TMR

  ensure_config /lib/systemd/system/gns3-config-serve-stop.service root 644 <<_EOF_CONF_SVC
[Unit]
Description=Stop and clean up GNS3 config server

[Service]
Type=oneshot
ExecStart=/bin/systemctl stop gns3-config-serve.service
ExecStart=/bin/systemctl disable gns3-config-serve.service
ExecStart=/bin/rm -rf ${CONFIG_SERVE_DIR}
ExecStart=/bin/systemctl disable gns3-config-serve-stop.timer
ExecStart=/usr/sbin/ufw delete allow ${CONFIG_SERVE_PORT}/tcp
_EOF_CONF_SVC

  enable_and_start gns3-config-serve.service
  enable_and_start gns3-config-serve-stop.timer

  log_ok "Config server live on port ${CONFIG_SERVE_PORT} (auto-stops in ${CONFIG_SERVE_HOURS}h)"

  # MOTD
  ensure_config /etc/update-motd.d/70-gns3-vpn root 755 <<_EOF_MOTD
#!/bin/sh
if systemctl is-active --quiet gns3-config-serve.service 2>/dev/null; then
  echo ""
  echo "  GNS3 config: http://${_lan_ip}:${CONFIG_SERVE_PORT}/"
  echo "  (auto-expires — download configs now)"
fi
_EOF_MOTD
}

### Firewall (ufw) ##########################################################

configure_firewall() {
  if [[ ${DISABLE_FIREWALL} -eq 1 ]]; then
    log_info "Skipping firewall configuration (--without-firewall)"
    return
  fi

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

  # Detect SSH source IP and local subnets for scoped rules
  local _remote_ssh_ip=""
  _remote_ssh_ip=$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')

  local -a _local_subnets=()
  readarray -t _local_subnets < <(ip -o -f inet addr show |
    grep -E '(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' |
    awk '{print $4}')

  if [[ -n ${_remote_ssh_ip} ]]; then
    log_info "SSH connection from ${_remote_ssh_ip}"
  else
    log_warn_sticky "No SSH session detected. Allow your IP in ufw or use VPN for remote access."
  fi

  if [[ ${#_local_subnets[@]} -gt 0 ]]; then
    log_info "RFC1918 subnets detected: ${_local_subnets[*]}"
  fi

  for _port in "${REQUIRED_PORTS[@]}"; do
    local _status="PERM"

    # VPN ports: allow from anywhere, both TCP and UDP
    case "${_port}" in
    $OVPN_PORT | $WG_PORT)
      ufw allow "${_port}"/tcp comment "GNS3 - ${_status} (VPN)" >/dev/null 2>&1
      ufw allow "${_port}"/udp comment "GNS3 - ${_status} (VPN)" >/dev/null 2>&1
      continue
      ;;
    "${CONFIG_SERVE_PORT}")
      _status="CLEAR"
      ufw allow "${_port}"/tcp comment "GNS3 - ${_status} (ephem. webserver)" >/dev/null 2>&1
      continue
      ;;
    esac

    # Non-VPN ports: scope to SSH source and local subnets
    if [[ -n ${_remote_ssh_ip} ]]; then
      ufw allow from "${_remote_ssh_ip}" to any port "${_port}" proto tcp \
        comment "GNS3 - ${_status}" >/dev/null 2>&1
    fi

    for _subnet in "${_local_subnets[@]}"; do
      ufw allow from "${_subnet}" to any port "${_port}" proto tcp \
        comment "GNS3 - ${_status}" >/dev/null 2>&1
    done
  done

  # Enable forwarding in ufw if any VPN is configured
  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    local _ufw_default="/etc/default/ufw"
    if [[ -f ${_ufw_default} ]]; then
      if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "${_ufw_default}"; then
        sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "${_ufw_default}"
        log_info "Set UFW DEFAULT_FORWARD_POLICY=ACCEPT"
      fi
    fi
    ufw reload >/dev/null 2>&1
  fi

  log_ok "ufw rules applied for ports: ${REQUIRED_PORTS[*]}"
}

### Core setup functions #################################################

setup_groups() {
  log_info "Creating required system groups..."
  for _grp in "${REQUIRED_GROUPS[@]}"; do
    ensure_group "${_grp}"
  done
  log_ok "Groups: ${REQUIRED_GROUPS[*]}"
}

setup_gns3_user() {
  log_info "Setting up GNS3 service user..."
  mkdir -p "${GNS3_HOME}"/{images,projects,appliances,configs}

  if ! id "${GNS3_USER}" &>/dev/null; then
    local _groups_csv
    printf -v _groups_csv '%s,' "${REQUIRED_GROUPS[@]}"
    _groups_csv="${_groups_csv%,}"

    useradd --system \
      --home-dir "${GNS3_HOME}" \
      --no-create-home \
      --comment "GNS3 server" \
      --groups "${_groups_csv}" \
      --shell /usr/sbin/nologin \
      "${GNS3_USER}"
    log_ok "Created user ${GNS3_USER}"
  else
    for _grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "${_grp}" "${GNS3_USER}"
    done
    log_ok "User ${GNS3_USER} already exists — updated groups"
  fi

  chown -R "${GNS3_USER}:${GNS3_USER}" "${GNS3_HOME}"
}

propagate_groups_to_invoker() {
  local _invoker
  _invoker=$(detect_invoking_user)
  if [[ -n ${_invoker} ]]; then
    log_info "Adding $_invoker to groups: ${REQUIRED_GROUPS[*]}"
    for _grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "${_grp}" "${_invoker}"
    done
    log_ok "Group membership updated for ${_invoker} (log out/in to take effect)"
  fi
}

gns3_repo_present() { 
  grep -rEq \ "(^(deb|URIs:).*ppa\.launchpadcontent\.net/gns3/${REPOSITORY})" \
  /etc/apt/sources.list.d/ 2>/dev/null 
  }

add_gns3_repository() {
  if gns3_repo_present; then
    log_info "GNS3 PPA already configured"
    return
  fi
  log_info "Adding GNS3 PPA: ppa:gns3/${REPOSITORY}"
  apt-add-repository -y "ppa:gns3/${REPOSITORY}" >/dev/null
  log_ok "GNS3 repository added"
}

add_docker_repository() {
  if [[ -f ${DOCKER_KEYRING} ]]; then
    log_info "Docker GPG key already present — skipping download"
  else
    log_info "Adding Docker CE repository..."
    install -m 0755 -d /etc/apt/keyrings

    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

    # Try local GPG file, their URL, my URL, then fail
    if ! fetch_resource "${DOCKER_KEYRING}" \
      "${_script_dir}/${REPO_DOCKER_GPG}" \
      "${DOCKER_BASE_URL}/gpg" \
      "${REPO_BASE_URL}${REPO_DOCKER_GPG}"; then
      log_fatal "Could not obtain Docker GPG key from any source."
    fi

    # Sanity check — make sure we got an actual key, not an error page
    if ! file "${DOCKER_KEYRING}" 2>/dev/null | grep -qiE 'pgp|openpgp|gpg'; then
      log_warn_sticky "Docker keyring file may not be a valid GPG key. Check: ${DOCKER_KEYRING}"
    fi

    chmod a+r "${DOCKER_KEYRING}"
  fi

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] ${DOCKER_BASE_URL} ${OS_CODENAME} stable
EOF
  log_ok "Docker repository configured"
}

# Do we need to run install?
needs_install() {
  local _pkg
  for _pkg in "${REQUIRED_PKGS[@]}"; do
    # dpkg-query is faster than apt-cache for this
    if ! dpkg-query -W -f='${Status}' "${_pkg}" 2>/dev/null | grep -q "install ok installed"; then
      return 0  # at least one package needs install
    fi
  done
  return 1  # everything installed
}

install_packages() {
  if [[ "${NO_SYSTEM_UPGRADE}" -eq 0 ]]; then
    log_info "Upgrading system packages..."
    apt_retry upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log_ok "System upgraded"
  else
    log_info "Skipping system upgrade"
  fi

  if needs_install; then
    log_info "Installing required packages..."
    NEEDRESTART_MODE=a apt_retry install -y "${REQUIRED_PKGS[@]}"
    log_ok "All packages installed"
  else
    log_ok "All required packages already installed"
  fi
}

### GNS3 server configuration #####################################

configure_gns3() {
  log_info "Writing GNS3 server configuration..."

  local _listen_host="0.0.0.0"

  local _hw_accel="True"
  if [[ ${DISABLE_KVM} -eq 1 ]]; then
    _hw_accel="False"
    log_warn "KVM disabled — Qemu performance will be degraded"
  fi

  ensure_directory "${GNS3_CONF_DIR}" "${GNS3_USER}" 700

  ensure_config "${GNS3_CONF_DIR}/gns3_server.conf" "${GNS3_USER}" 600 <<_EOF_GNS3_CONF
${DEPLOY_MARKER}
[Server]
host = ${_listen_host}
port = ${GNS3_PORT}
images_path = ${GNS3_HOME}/images
projects_path = ${GNS3_HOME}/projects
appliances_path = ${GNS3_HOME}/appliances
configs_path = ${GNS3_HOME}/configs
report_errors = True

[Qemu]
enable_hardware_acceleration = ${_hw_accel}
require_hardware_acceleration = ${_hw_accel}
_EOF_GNS3_CONF

  log_ok "GNS3 configuration written"
}

### Systemd service #############################################

install_gns3_service() {
  log_info "Installing GNS3 systemd service..."

  local _gns3_bin="/usr/bin/gns3server"
  if [[ -x "${GNS3_VENV}/bin/gns3server" ]]; then
    _gns3_bin="${GNS3_VENV}/bin/gns3server"
    log_info "Using venv binary: ${_gns3_bin}"
  fi

  ensure_config "${GNS3_SERVICE_FILE}" root 644 <<_EOF_GNS3_SVC
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
ExecStart=${_gns3_bin} --log /var/log/gns3/gns3.log
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
_EOF_GNS3_SVC

  enable_and_start gns3
  log_ok "GNS3 service installed and enabled"
}

### OpenVPN setup ################################################

configure_openvpn() {
  log_info "Configuring OpenVPN..."

  local _public_ip
  _public_ip=$(get_public_ip)
  if [[ ${_public_ip} == "UNKNOWN" ]]; then
    log_fatal "Could not determine public IP for OpenVPN configuration."
  fi
  log_info "Public IP detected: ${_public_ip}"

  local _hostname
  _hostname=$(hostname)

  log_info "Generating OpenVPN keys..."
  ensure_directory "${OVPN_CONF_DIR}" root 755

  if [[ ${USE_LEGACY_RSA} -eq 1 ]]; then
    log_info "Using legacy RSA crypto (DH params may take a minute)..."
    [[ -f "${OVPN_CONF_DIR}/dh.pem" ]] || openssl dhparam -quiet 2048 | ensure_config "${OVPN_CONF_DIR}/dh.pem" root 600
    require_file "${OVPN_CONF_DIR}/dh.pem" "OpenVPN DH params" || log_fatal "DH param generation failed"

    [[ -f "${OVPN_CONF_DIR}/key.pem" ]] || openssl genrsa 2048 | ensure_config "${OVPN_CONF_DIR}/key.pem" root 600
  else
    log_info "Using elliptic curve crypto (P-384)..."
    [[ -f "${OVPN_CONF_DIR}/key.pem" ]] || openssl ecparam -name secp384r1 -genkey -noout | ensure_config "${OVPN_CONF_DIR}/key.pem" root 600
  fi
  require_file "${OVPN_CONF_DIR}/key.pem" "OpenVPN private key" || log_fatal "Key generation failed"
  chmod 600 "${OVPN_CONF_DIR}/key.pem"

  [[ -f "${OVPN_CONF_DIR}/csr.pem" ]] || openssl req -new -key "${OVPN_CONF_DIR}/key.pem" \
    -out "${OVPN_CONF_DIR}/csr.pem" -subj /CN=OpenVPN/ 2>/dev/null
  require_file "${OVPN_CONF_DIR}/csr.pem" "OpenVPN CSR" || log_fatal "CSR generation failed"

  [[ -f "${OVPN_CONF_DIR}/cert.pem" ]] || openssl x509 -req -in "${OVPN_CONF_DIR}/csr.pem" \
    -out "${OVPN_CONF_DIR}/cert.pem" -signkey "${OVPN_CONF_DIR}/key.pem" -days 3650 &>/dev/null
  require_file "${OVPN_CONF_DIR}/cert.pem" "OpenVPN certificate" || log_fatal "Certificate signing failed"

  local _dh_client_block=""
  local _dh_server_line="dh none"
  if [[ ${USE_LEGACY_RSA} -eq 1 ]]; then
    _dh_client_block="<dh>
$(cat "${OVPN_CONF_DIR}/dh.pem")
</dh>"
    _dh_server_line="dh dh.pem"
  fi

  ensure_config /root/client.ovpn root 600 <<_EOF_OVPN_CLI
client
nobind
dev tun
<key>
$(cat "${OVPN_CONF_DIR}/key.pem")
</key>
<cert>
$(cat "${OVPN_CONF_DIR}/cert.pem")
</cert>
<ca>
$(cat "${OVPN_CONF_DIR}/cert.pem")
</ca>
${_dh_client_block}
<connection>
remote ${_public_ip} ${OVPN_PORT} udp
</connection>
_EOF_OVPN_CLI

  ensure_config "${OVPN_CONF_DIR}/udp${OVPN_PORT}.conf" root 644 <<_EOF_OVPN
server 172.16.253.0 255.255.255.0
verb 3
duplicate-cn
key key.pem
ca cert.pem
cert cert.pem
${_dh_server_line}
keepalive 10 60
persist-key
persist-tun
proto udp
port ${OVPN_PORT}
dev tun${OVPN_PORT}
status openvpn-status-${OVPN_PORT}.log
log-append /var/log/openvpn-udp${OVPN_PORT}.log
_EOF_OVPN

  enable_and_start openvpn
  log_ok "OpenVPN configured"
}

### WireGuard setup #############################################─

configure_wireguard() {
  log_info "Configuring WireGuard..."

  local _public_ip
  _public_ip=$(get_public_ip)
  if [[ ${_public_ip} == "UNKNOWN" ]]; then
    log_fatal "Could not determine public IP for WireGuard configuration."
  fi

  ensure_directory "${WG_CONF_DIR}" root 700

  if [[ ! -f "${WG_CONF_DIR}/server.key" ]]; then
    (
      umask 077
      wg genkey | tee "${WG_CONF_DIR}/server.key" | wg pubkey >"${WG_CONF_DIR}/server.pub"
    )
  fi
  require_file "${WG_CONF_DIR}/server.key" "WireGuard server private key" || log_fatal "WG server keygen failed"
  require_file "${WG_CONF_DIR}/server.pub" "WireGuard server public key" || log_fatal "WG server keygen failed"

  local _server_privkey _server_pubkey
  _server_privkey=$(cat "${WG_CONF_DIR}/server.key")
  _server_pubkey=$(cat "${WG_CONF_DIR}/server.pub")

  if [[ ! -f "${WG_CONF_DIR}/client1.key" ]]; then
    (
      umask 077
      wg genkey | tee "${WG_CONF_DIR}/client1.key" | wg pubkey >"${WG_CONF_DIR}/client1.pub"
    )
  fi
  require_file "${WG_CONF_DIR}/client1.key" "WireGuard client private key" || log_fatal "WG client keygen failed"

  local _client_privkey _client_pubkey
  _client_privkey=$(cat "${WG_CONF_DIR}/client1.key")
  _client_pubkey=$(cat "${WG_CONF_DIR}/client1.pub")

  ensure_config "${WG_CONF_DIR}/wg0.conf" root 600 <<_EOF_WG_SRV
[Interface]
Address = 172.16.254.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${_server_privkey}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# client1
PublicKey = ${_client_pubkey}
AllowedIPs = 172.16.254.2/32
_EOF_WG_SRV

  ensure_config "${WG_CONF_DIR}/client1.conf" root 600 <<_EOF_WG_CLI
[Interface]
Address = 172.16.254.2/24
PrivateKey = ${_client_privkey}
DNS = 1.1.1.1

[Peer]
PublicKey = ${_server_pubkey}
Endpoint = ${_public_ip}:${WG_PORT}
AllowedIPs = 172.16.253.0/24, 172.16.254.0/24
PersistentKeepalive = 25
_EOF_WG_CLI

  enable_and_start wg-quick@wg0
  log_ok "WireGuard configured"
}

### Welcome setup ##############################################################─

configure_welcome() {
  log_info "Setting up GNS3-VM welcome console..."

  ensure_config "/etc/sudoers.d/gns3" root 440 <<_EOF
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-key
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-get
gns3   ALL = (ALL) NOPASSWD: /usr/sbin/reboot
_EOF

if ! visudo -cf /etc/sudoers.d/gns3 &>/dev/null; then
  log_warn_sticky "sudoers fragment failed syntax check — removing"
  rm -f /etc/sudoers.d/gns3
fi

  curl -fsSL https://raw.githubusercontent.com/GNS3/gns3-server/master/scripts/welcome.py \
    -o /usr/local/bin/welcome.py
  chmod 755 /usr/local/bin/welcome.py
  chown "${GNS3_USER}:${GNS3_USER}" /usr/local/bin/welcome.py

  mkdir -p /etc/systemd/system/getty@tty1.service.d
  ensure_config "/etc/systemd/system/getty@tty1.service.d/override.conf" root 644 <<'_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a gns3 --noclear %I $TERM
_EOF

  grep -q 'welcome.py' "${GNS3_HOME}/.bashrc" 2>/dev/null ||
    echo "python3 /usr/local/bin/welcome.py" >>"${GNS3_HOME}/.bashrc"

  echo "gns3:gns3" | chpasswd
  usermod --shell /bin/bash "${GNS3_USER}"
  usermod -aG sudo "${GNS3_USER}"

  log_ok "Welcome console configured"
}

### Start services ##########################################################

start_services() {
  log_info "Starting GNS3 service..."
  systemctl restart gns3
  sleep 2

  if systemctl is-active --quiet gns3; then
    log_ok "GNS3 service running"
  else
    log_warn_sticky "GNS3 service failed to start"
    log_warn_sticky "  Check logs: journalctl -u gns3 --no-pager -n 20"
  fi

  if [[ ${WITH_DOCKER} -eq 1 ]]; then
    enable_and_start docker
    if systemctl is-active --quiet docker; then
      log_ok "Docker service running"
    else
      log_warn_sticky "Docker service failed to start"
    fi
  fi
}

### Post-install validation ##################################################

# Helper: curl a URL and report success/failure. Returns 0/1 for chaining.
probe_http() {
  local _url="$1" _desc="$2"
  if curl -sf --max-time 5 "${_url}" &>/dev/null; then
    log_ok "${_desc} responding: ${_url}"
    return 0
  fi
  log_warn_sticky "${_desc} not responding: ${_url}"
  return 1
}

# Helper: check if a TCP port is listening
probe_port_listening() {
  local _port="$1" _desc="$2"
  if ss -tlnH 2>/dev/null | grep -q ":${_port} "; then
    log_ok "${_desc} listening on port ${_port}"
    return 0
  fi
  log_warn_sticky "${_desc} not listening on port ${_port}"
  return 1
}

validate() {
  log_info "Running post-install validation..."
  local _lan_ip _serve_slug
  _lan_ip=$(get_lan_ip)

  sleep 3

  # GNS3 API responding
  if ! probe_http "http://${_lan_ip}:${GNS3_PORT}/v2/version" "GNS3 API"; then
    probe_http "http://localhost:${GNS3_PORT}/v2/version" "GNS3 API (localhost fallback)" ||
      log_warn_sticky "  Check: journalctl -u gns3 --no-pager -n 20"
  fi

  # Port listening checks
  probe_port_listening "${GNS3_PORT}" "GNS3 server"
  probe_port_listening "${CONFIG_SERVE_PORT}" "Config server"

  # Config server landing page
  probe_http "http://${_lan_ip}:${CONFIG_SERVE_PORT}/" "Landing page" || true

  # VPN config downloadable through the slug path
  if [[ -f "${DEPLOY_DIR}/serve_slug" ]]; then
    _serve_slug=$(cat "${DEPLOY_DIR}/serve_slug")
    if [[ ${WITH_WIREGUARD} -eq 1 ]]; then
      probe_http "http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/w" "WireGuard config download" || true
    fi
    if [[ ${WITH_OPENVPN} -eq 1 ]]; then
      probe_http "http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/o" "OpenVPN config download" || true
    fi
  fi

  # VPN tunnel interfaces
  if [[ ${WITH_WIREGUARD} -eq 1 ]]; then
    probe_port_listening "${WG_PORT}" "WireGuard"
    if ip link show wg0 &>/dev/null; then
      log_ok "WireGuard interface wg0 is up"
    else
      log_warn_sticky "WireGuard interface wg0 not found"
    fi
  fi

  if [[ ${WITH_OPENVPN} -eq 1 ]]; then
    if ip link show "tun${OVPN_PORT}" &>/dev/null; then
      log_ok "OpenVPN interface tun${OVPN_PORT} is up"
    else
      log_warn_sticky "OpenVPN interface tun${OVPN_PORT} not found"
    fi
  fi

  # Config server auto-stop timer armed
  if systemctl list-timers --all 2>/dev/null | grep -q "gns3-config-serve-stop"; then
    log_ok "Config server auto-stop timer armed"
  else
    log_warn_sticky "Config server auto-stop timer NOT armed — server will not expire on schedule"
  fi

  # Sysctl hardening applied
  if [[ -f /etc/sysctl.d/90-gns3-hardening.conf ]]; then
    log_ok "Sysctl hardening file present"
  else
    log_warn_sticky "Sysctl hardening file missing"
  fi

  # IP forwarding enabled when VPN configured
  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
      log_ok "IPv4 forwarding enabled"
    else
      log_warn_sticky "IPv4 forwarding NOT enabled — VPN routing will fail"
    fi
  fi

  # Deploy dir perms — secrets must not be world-readable
  if [[ -d ${DEPLOY_DIR} ]]; then
    local _mode
    _mode=$(stat -c %a "${DEPLOY_DIR}" 2>/dev/null)
    if [[ ${_mode} == "700" ]]; then
      log_ok "Deploy directory permissions: 700"
    else
      log_warn_sticky "Deploy directory permissions are ${_mode}, expected 700"
    fi
  fi

  # Docker
  if [[ ${WITH_DOCKER} -eq 1 ]]; then
    if docker info &>/dev/null; then
      log_ok "Docker engine responding"
    else
      log_warn_sticky "Docker installed but not responding"
    fi
  fi

  # GNS3 binary sanity
  local _gns3_bin="/usr/bin/gns3server"
  [[ -x "${GNS3_VENV}/bin/gns3server" ]] && _gns3_bin="${GNS3_VENV}/bin/gns3server"
  if "${_gns3_bin}" --version &>/dev/null; then
    log_ok "gns3server binary: $(${_gns3_bin} --version 2>&1 | head -1)"
  else
    log_warn_sticky "gns3server binary cannot execute — possible Python venv issue"
    log_warn_sticky "  Binary: ${_gns3_bin}"
    log_warn_sticky "  Check:  ${_gns3_bin} --version"
  fi

  # UFW active when firewall configuration was attempted
  if [[ ${DISABLE_FIREWALL} -eq 0 ]] && command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      log_ok "UFW active"
    else
      log_warn_sticky "UFW is installed but not active — no firewall rules enforced"
    fi
  fi

  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    log_ok "All post-install checks passed"
  fi
}

### Summary banner ##########################################################

print_summary() {
  local _lan_ip _public_ip
  _lan_ip=$(get_lan_ip)
  _public_ip=$(get_public_ip)

  echo ""
  printf "${GREEN}${BOLD}  GNS3 Server Install Complete${NC}\n"
  printf "  ##################################\n\n"
  printf "  Server: http://%s:%s\n" "${_lan_ip}" "${GNS3_PORT}"
  printf "  Config: %s/gns3_server.conf\n" "${GNS3_CONF_DIR}"
  printf "  Data:   %s/\n" "${GNS3_HOME}"
  echo "  Logs:   /var/log/gns3/gns3.log"
  echo "  Status: systemctl status gns3"
  echo ""

  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    echo "  VPN"
    echo "  ##################################"

    if [[ ${WITH_WIREGUARD} -eq 1 ]]; then
      printf "  WireGuard: %s:%s\n" "${_public_ip}" "${WG_PORT}"
      printf "    Tunnel:  172.16.254.1:%s\n" "${GNS3_PORT}"
    fi

    if [[ ${WITH_OPENVPN} -eq 1 ]]; then
      printf "  OpenVPN:   %s:%s/udp\n" "${_public_ip}" "${OVPN_PORT}"
      printf "    Tunnel:  172.16.253.1:%s\n" "${GNS3_PORT}"
    fi
    echo ""
  fi

  # Config server info
  if [[ -f "${DEPLOY_DIR}/serve_slug" ]]; then
    local _serve_slug
    _serve_slug=$(cat "${DEPLOY_DIR}/serve_slug")
    printf "  Landing page:\n"
    printf "  http://%s:%s/\n" "${_lan_ip}" "${CONFIG_SERVE_PORT}"
    printf "  ${YELLOW}Expires in %sh${NC}\n\n" "${CONFIG_SERVE_HOURS}"
  fi

  # Encrypted config download commands
  if [[ -f "${DEPLOY_DIR}/passphrase" ]]; then
    local _pass _serve_slug
    _pass=$(cat "${DEPLOY_DIR}/passphrase")
    _serve_slug=$(cat "${DEPLOY_DIR}/serve_slug")

    echo "  Secure config download"
    echo "  ##################################"

    if [[ ${WITH_WIREGUARD} -eq 1 ]]; then
      printf "  ${CYAN}WireGuard:${NC}\n"
      echo "  curl -s http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/w | openssl aes-256-cbc -d -pbkdf2 -pass pass:${_pass} -a > wg.conf"
      echo ""
    fi

    if [[ ${WITH_OPENVPN} -eq 1 ]]; then
      printf "  ${CYAN}OpenVPN:${NC}\n"
      echo "  curl -s http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/o | openssl aes-256-cbc -d -pbkdf2 -pass pass:${_pass} -a > conf.ovpn"
      echo ""
    fi
  fi

  if [[ ${DISABLE_KVM} -eq 1 ]]; then
    printf "  ${YELLOW}KVM: DISABLED${NC}\n"
    echo ""
  fi

  local _invoker
  _invoker=$(detect_invoking_user)
  if [[ -n ${_invoker} ]]; then
    printf "  ${CYAN}Log out/in as ${_invoker}${NC}"
    echo " for group changes"
    echo ""
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf "  ${YELLOW}${BOLD}Action Required${NC}\n"
    echo "  ##################################"
    for _warning in "${WARNINGS[@]}"; do
      printf "  ${YELLOW}!${NC} %s\n" "${_warning}"
    done
    echo ""
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  export DEBIAN_FRONTEND="noninteractive"

  if ! is_root; then
    log_fatal "Must run as root. Try: sudo $0"
  fi

  # Ensure exclusive execution
  exec 9>/var/lock/gns3-install.lock
  if ! flock -n 9; then
    log_fatal "Another instance of this script is already running."
  fi

  log_info "Bootstrapping essential packages..."
  apt-get update -qq >/dev/null 2>&1 &&
    log_info "Update done"
  apt-get install -y -qq curl software-properties-common >/dev/null 2>&1 &&
    log_info "Installed curl"
  log_ok "Bootstrap complete"

  set -euo pipefail
  trap 'systemctl start gns3 2>/dev/null || true; log_error "Failed at line $LINENO."' ERR
  trap 'log_warn "Interrupted by user."; exit 130' INT TERM

  # Initialize deploy directory for secrets and state
  mkdir -p "${DEPLOY_DIR}"
  chmod 700 "${DEPLOY_DIR}"

  # Log everything to file for post-mortem
  exec > >(tee -a "${DEPLOY_DIR}/install.log") 2>&1

  preflight_checks

  readonly OS_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

  # # Phase 1: Repositories ##################################################

  add_gns3_repository
  if [[ ${WITH_DOCKER} -eq 1 ]]; then add_docker_repository; fi

  # # Phase 2: Packages (single apt pass) ####################################

  install_packages

  # # Phase 3: Users and groups ##############################################

  setup_groups
  setup_gns3_user
  propagate_groups_to_invoker

  # # Phase 4: Configuration ################################################─

  configure_gns3
  install_gns3_service

  if [[ ${WITH_OPENVPN} -eq 1 ]]; then configure_openvpn; fi
  if [[ ${WITH_WIREGUARD} -eq 1 ]]; then configure_wireguard; fi
  if [[ ${WITH_WELCOME} -eq 1 ]]; then configure_welcome; fi
  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    enable_ip_forwarding
  fi

  setup_config_server
  configure_firewall
  apply_sysctl_hardening

  # ## Phase 5: Start ##########################################################

  start_services

  # ## Phase 6: Validate ######################################################

  validate

  # ## Phase 7: Welcome post-install repair ####################################

  if [[ ${WITH_WELCOME} -eq 1 ]]; then
    python3 -c 'import sys; sys.path.append("/usr/local/bin/"); import welcome; ws = welcome.Welcome_dialog(); ws.repair_remote_install()' || true
  fi

  # ## Done ####################################################################

  print_summary
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
