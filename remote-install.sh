#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'

readonly _BINS_="/usr/local/bin:/usr/bin:/bin"
readonly _SBINS_="/usr/local/sbin:/usr/sbin:/sbin"
export PATH="${_BINS_}:${_SBINS_}"
readonly PATH

############################################################
# Filename   : gns3-remote.sh                              #
# Author     : Shane Sexton                                #
# Created    : April 18 2026                               #
# Last edit  : April 22 2026                               #
# Purpose    : Enhancement to remote-install.sh            #
# Reference  : GNS3:gns3-server - remote-install.sh        #
# Depends    : Ubuntu Server 22.04, 24.04, 26.04 LTS       #
# To do      : Consistency, readability, & structure need  #
#              improvements at all magnification levels    #
############################################################

############################################################
# PLEASE SEE README FOR FEATURE COMPARISON                 #
############################################################

########################################################################
# Usage: sudo ./gns3-remote-install-redux.sh [OPTIONS]                 #
#                                                                      #
#  --with-openvpn            Install & configure OpenVPN               #
#  --with-wireguard          Install & configure WireGuard             #
#  --with-welcome            Install GNS3-VM welcome.py console UI     #
#  --without-kvm             Disable KVM (hurts Qemu performance)      #
#  --without-docker          Skip Docker installation                  #
#  --without-firewall        Skip automatic UFW rule configuration     #
#  --without-system-upgrade  Skip apt upgrade                          #
#  --unsafe-configs          Serve VPN configs unencrypted (less safe) #
#  --unstable                Use GNS3 unstable PPA                     #
#  --custom-repository REPO  Use custom GNS3 PPA name                  #
#  -h, --help                Show this help                            #
########################################################################

### Constants ################################################################
# This repo
readonly _REPO_BASE_URL_="https://raw.githubusercontent.com/lark-cx/gns3-server-deploy/refs/heads/main/"
readonly _REPO_LANDING_HTML_="templates/template.html"
readonly _REPO_DOCKER_GPG_="resources/docker-gpg"
readonly _REPO_WELCOME_PY_="resources/welcome.py"
readonly _TEMPLATE_CONFIG_SERVE_SERVICE_="templates/gns3-config-serve.service.temp"
readonly _TEMPLATE_CONFIG_SERVE_STOP_SERVICE_="templates/gns3-config-serve-stop.service"
readonly _TEMPLATE_CONFIG_SERVE_TIMER_="templates/gns3-config-serve.timer.temp"
readonly _TEMPLATE_GNS3_SERVICE_="templates/gns3.service.temp"
readonly _TEMPLATE_GNS3_SERVER_CONF_="templates/gns3_server.conf.temp"
readonly _TEMPLATE_MOTD_="templates/70-gns3-vpn.temp"
readonly _TEMPLATE_WG_CLIENT_="templates/client1.conf.temp"
readonly _TEMPLATE_WG_SERVER_="templates/wg0.conf.temp"
# Docker
readonly _DOCKER_BASE_URL_="https://download.docker.com/linux/ubuntu"
readonly _DOCKER_KEYRING_="/etc/apt/keyrings/docker.asc"
# GNS3 configurations
readonly _GNS3_USER_="gns3"
readonly _GNS3_HOME_="/opt/gns3"
readonly _GNS3_CONF_DIR_="/etc/gns3"
readonly _GNS3_PORT_=3080
readonly _GNS3_SERVICE_FILE_="/etc/systemd/system/gns3.service"
readonly _GNS3_VENV_="/usr/share/gns3/gns3-server"
# Config deployment server
readonly _CONFIG_SERVE_PORT_=8003
readonly _CONFIG_SERVE_DIR_="/var/lib/gns3-config-serve"
readonly _CONFIG_SERVE_HOURS_=2
readonly _DEPLOY_MARKER_="# deployed by gns3-remote-install-redux"
readonly _DEPLOY_DIR_="/root/.gns3-deploy"

### VPN Constants #############################################################
readonly _OVPN_CONF_DIR_="/etc/openvpn"
readonly _OVPN_PORT_=1194
readonly _WG_CONF_DIR_="/etc/wireguard"
readonly _WG_PORT_=51820

### Colors ####################################################################
readonly _RED_=$'\033[0;31m'
readonly _GREEN_=$'\033[0;32m'
readonly _YELLOW_=$'\033[1;33m'
readonly _CYAN_=$'\033[0;36m'
readonly _BOLD_=$'\033[1m'
readonly _BOLD_RED_=$'\033[1;31m'
readonly _RST_=$'\033[0m'

# ===================================================================
# LOGGING
# ===================================================================
_log() {
  local _level="${1:-}"
  shift || true

  local _message="${*}"
  local _ts=""
  local _color="${_RST_}"
  local _prefix="LOG"

  _ts="$(date +"%H:%M:%S")"

  case "${_level}" in
    info)  _color="${_CYAN_}";     _prefix="INFO"  ;;
    ok)    _color="${_GREEN_}";    _prefix="OK"    ;;
    warn)  _color="${_YELLOW_}";   _prefix="WARN"  ;;
    error) _color="${_RED_}";      _prefix="ERROR" ;;
    fatal) _color="${_BOLD_RED_}"; _prefix="FATAL" ;;
  esac

  printf "%s%s [%s]: %s%s\n" \
    "${_color}" "${_ts}" "${_prefix}" "${_message}" "${_RST_}" >&2
}

log_info()  { _log info  "${@}"; }
log_ok()    { _log ok    "${@}"; }
log_warn()  { _log warn  "${@}"; }
log_error() { _log error "${@}"; }

log_fatal() {
  _log fatal "${@}"
  exit 1
}

log_warn_sticky() {
  _log warn "${@}"
  WARN_MESSAGES+=("${*}")
  WARNINGS_OCCURRED=1
}


on_error() {
  local _line_no="${1:-}"
  local _cmd="${2:-}"
  local _exit_code="${3:-}"

  log_error "Failed at line ${_line_no}: ${_cmd} (exit ${_exit_code})"

  # Only try to revive GNS3 if systemd knows about it
  if systemctl list-unit-files gns3.service >/dev/null 2>&1; then
    # shellcheck disable=SC2310
    systemctl daemon-reload >/dev/null 2>&1 || true
    sleep 2
    # shellcheck disable=SC2310
    systemctl restart gns3 >/dev/null 2>&1 || systemctl start gns3 >/dev/null 2>&1 || true
  fi

  exit "${_exit_code}"
}

# Testability wrapper — EUID is readonly in bash, so tests override this function
is_root() { [[ "${EUID}" -eq 0 ]]; }

### Mutable arrays (built up by option flags) ##############################
REQUIRED_CMDS=(apt apt-add-repository dpkg chown chmod useradd usermod lsmod modprobe systemctl ss ip openssl grep sed awk hostname mktemp tee file stat)
REQUIRED_PORTS=("${_GNS3_PORT_}")
REQUIRED_GROUPS=(kvm ubridge)
REQUIRED_MODS=(kvm)
WARN_MESSAGES=()
WARNINGS_OCCURRED=0

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

readonly _PKGS_OPENVPN_=(openvpn dnsutils)
readonly _PKGS_WIREGUARD_=(wireguard-tools)
readonly _PKGS_DOCKER_=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly _PKGS_WELCOME_=(net-tools dialog python3-dialog)

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

### Help ####################################################################

show_help() {
  cat >&2 <<_EOF_HELP
${_BOLD_}gns3-remote-install-redux.sh${_RST_} — GNS3 remote server installer

${_BOLD_}Usage:${_RST_} sudo ${0} [OPTIONS]

${_BOLD_}Options:${_RST_}
  --with-openvpn            Install and configure OpenVPN
  --with-wireguard          Install and configure WireGuard
  --with-welcome            Install GNS3-VM welcome.py console UI
  --without-kvm             Disable KVM hardware acceleration
  --without-docker          Skip Docker CE installation
  --without-firewall        Skip automatic UFW rule configuration
  --without-system-upgrade  Skip apt upgrade step
  --legacy-rsa              Use RSA instead of ECC (OpenVPN)
  --unsafe-configs          Serve VPN configs unencrypted
  --unstable                Use the GNS3 unstable PPA
  --custom-repository REPO  Use a custom GNS3 PPA name
  -h, --help                Show this help
_EOF_HELP
}

### Argument parsing ##########################################################

parse_args() {
  local _arg=""

  while [[ "${#}" -gt 0 ]]; do
    _arg="${1:-}"

    case "${_arg}" in
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
        shift
        if [[ "${#}" -eq 0 || "${1:-}" == --* ]]; then
          log_fatal "--custom-repository requires a repository name"
        fi
        REPOSITORY="${1}"
        shift
        ;;
      -h | --help)
        show_help
        exit 0
        ;;
      *)
        log_fatal "Unknown option: ${_arg}"
        ;;
    esac
  done
}

### Roll up arrays based on flags ##########################################

apply_option_flags() {
  if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
    REQUIRED_PORTS+=("${_OVPN_PORT_}")
    REQUIRED_PKGS+=("${_PKGS_OPENVPN_[@]}")
  fi

  if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
    REQUIRED_PORTS+=("${_WG_PORT_}")
    REQUIRED_MODS+=(wireguard)
    REQUIRED_PKGS+=("${_PKGS_WIREGUARD_[@]}")
  fi

  # Config server port always needed (landing page is default-on)
  REQUIRED_PORTS+=("${_CONFIG_SERVE_PORT_}")

  if [[ "${WITH_DOCKER}" -eq 1 ]]; then
    REQUIRED_PKGS+=("${_PKGS_DOCKER_[@]}")
    REQUIRED_GROUPS+=(docker)
  fi

  if [[ "${WITH_WELCOME}" -eq 1 ]]; then
    REQUIRED_PKGS+=("${_PKGS_WELCOME_[@]}")
  fi
}
### Boolean Helpers  ########################################################

file_exists()       { [[ -f "${1:-}" ]]; }
var_exists()        { [[ -n "${1:-}" ]]; }
dir_exists()        { [[ -d "${1:-}" ]]; }
port_open()         { ss -tlnp | grep -q ":${1:-} " ; }

### Preflight checks ########################################################

preflight_checks() {
  local _has_errors=0

  if [[ "${OSTYPE}" != linux-gnu* ]]; then
    log_fatal "This script requires Linux (detected: ${OSTYPE})."
  fi

# shellcheck disable=SC2310
  if file_exists /etc/os-release; then
    source /etc/os-release
  else
    log_fatal "/etc/os-release not found. Is this Ubuntu?"
  fi

  if [[ "${ID:-}" != "ubuntu" ]]; then
    log_fatal "This script requires Ubuntu (detected: ${ID:-unknown})."
  fi

  local -a _missing_cmds=()
  for _cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${_cmd}" &>/dev/null; then
      _missing_cmds+=("${_cmd}")
    fi
  done
  # shellcheck disable=SC2310
  if [[ "${#_missing_cmds[@]}" -gt 0 ]]; then
    log_error "Missing commands: ${_missing_cmds[*]}"
    _has_errors=1
  fi

  # Detect reconfigure: our config marker + gns3 service running
  # # shellcheck disable=SC2310
  if dir_exists "${_DEPLOY_DIR_}"; then
    log_info "Existing installation detected — running in reconfigure mode"
    systemctl stop gns3 2>/dev/null || true
    systemctl stop gns3-config-serve.service 2>/dev/null || true
  fi

  local -a _busy_ports=()
  for _port in "${REQUIRED_PORTS[@]}"; do
    if ss -lnH | grep -q ":${_port} "; then
      _busy_ports+=("${_port}")
    fi
  done
  if [[ "${#_busy_ports[@]}" -gt 0 ]]; then
    log_error "Port(s) already in use: ${_busy_ports[*]}"
    _has_errors=1
  fi

  # Ensure time synchronization is active for VPN certificate validity
  if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true || log_warn_sticky "Couldn't start NTP. Ensure accurate time for certs."
  fi

  # Load missing kernel modules automatically unless --without-kvm
  local -a _missing_mods=()
  for _mod in "${REQUIRED_MODS[@]}"; do
    if ! lsmod | grep -wq "${_mod}" 2>/dev/null; then
      if [[ "${_mod}" == "kvm" && ${DISABLE_KVM} -eq 1 ]]; then
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
  if [[ "${#_missing_mods[@]}" -gt 0 ]]; then
    log_warn_sticky "Kernel module(s) could not be loaded: ${_missing_mods[*]}"
    log_warn_sticky "  Manual fix: modprobe ${_missing_mods[*]}"
  fi

  if [[ "${DISABLE_KVM}" -eq 0 ]] && [[ $(grep -Ec '(vmx|svm)' /proc/cpuinfo) -eq 0 ]]; then
    log_warn_sticky "CPU virtualization extensions not detected. KVM will not function."
    log_warn_sticky "  If running in a VM without nested virt, pass --without-kvm"
  fi

  if [[ "${REPOSITORY}" == "ppa-v3" ]]; then
    if ! python3 -c 'import sys; assert sys.version_info >= (3,9)' &>/dev/null; then
      log_error "GNS3 v3+ requires Python >= 3.9"
      _has_errors=1
    fi
  fi

  if [[ "${_has_errors}" -eq 1 ]]; then
    log_fatal "Preflight failed. Fix the above and re-run."
  fi

  log_ok "Preflight checks passed"
}

### Helpers ##################################################################

# Retry apt operation 3 times, quietly.
# Return final lines from apt on failure.
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

# Groups exists or is created
ensure_group() {
  if ! getent group "${1:-}" &>/dev/null; then
    groupadd --system "${1:-}"
  fi
}

# Who invoked the script with sudo?
detect_invoking_user() {
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
    echo "${SUDO_USER}"
  fi
}

# Get public IP with fallback chain (dig → curl → UNKNOWN)
get_public_ip() {
  local _ip=""

  if command -v dig &>/dev/null; then
    _ip=$(dig @ns1.google.com -t txt o-o.myaddr.l.google.com +short -4 2>/dev/null | sed 's/"//g') || true
    if var_exists "${_ip}"; then
      echo "${_ip}"
      return
    fi
  fi
  _ip=$(curl -sf --max-time 5 https://icanhazip.com 2>/dev/null)
  # shellcheck disable=SC2310
  if var_exists "${_ip}"; then
    echo "${_ip}"
    return
  fi
  _ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)
  # shellcheck disable=SC2310
  if var_exists "${_ip}"; then
    echo "${_ip}"
    return
  fi
  echo "UNKNOWN"
}

# Get LAN IP — primary interface address
get_lan_ip() {
  local _ip
  _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -n "${_ip}" ]]; then
    echo "${_ip}"
  else
    echo "127.0.0.1"
  fi
}

# Generate a readable one-time passphrase: XXXX-XXXX-####
generate_passphrase() {
  local _hex
  _hex=$(openssl rand -hex 4)
  printf "%s-%s" "${_hex:0:4}" "${_hex:4:4}" | tr 'a-f' 'A-F'
}

# Encrypt a file with a passphrase, output .enc alongside original
encrypted_copy() {
  local _src="${1:-}" _dst="${2:-}" _pass="${3:-}"
  openssl enc -aes-256-cbc -pbkdf2 -pass "pass:${_pass}" -a -in "${_src}" -out "${_dst}"
}

# Enable IPv4 forwarding, if needed
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
  local _key=""
  local _val=""

  : >"${_sysctl_file}"

  for _key in "${!_sysctls[@]}"; do
    _val="${_sysctls[${_key}]}"
    echo "${_key}=${_val}" >>"${_sysctl_file}"
    sysctl -w "${_key}=${_val}" >/dev/null 2>&1
  done

  log_ok "Sysctl hardening applied (${_sysctl_file})"
}

# Safe and quiet service (re)start - with mulligan
enable_and_start() {
  local _svc="${1:-}"
  local _attempt _max=3

  log_info "Enabling and starting service: ${_svc}"
  systemctl daemon-reload
  systemctl enable "${_svc}" >/dev/null 2>&1 || true

  for ((_attempt=1; _attempt<=_max; _attempt++)); do
    if systemctl restart "${_svc}" >/dev/null 2>&1 || systemctl start "${_svc}" >/dev/null 2>&1; then
      log_ok "Service running: ${_svc}"
      return 0
    fi

    if [[ ${_attempt} -lt ${_max} ]]; then
      log_warn "Service start failed for ${_svc} (attempt ${_attempt}/${_max}); retrying in 1s..."
      sleep 1
      systemctl daemon-reload
    fi
  done

  log_warn_sticky "Service failed after ${_max} attempts: ${_svc}"
  log_warn_sticky "  Check: journalctl -u ${_svc} --no-pager -n 30"
  return 1
}

# Verify a file exists and is non-empty.
# Returns 1 and logs sticky warning on failure.
require_file() {
  local _path="${1:-}" _desc="${2:-file}"
  # shellcheck disable=SC2310
  if [[ ! -s ${_path} ]]; then
    log_warn_sticky "${_desc} missing or empty: ${_path}"
    return 1
  fi
  return 0
}

# Idempotent directory creation with ownership and mode. Creates if missing,
# applies chown/chmod either way (in case perms drifted).
ensure_directory() {
  local _path="${1:-}" _owner="${2:-root}" _mode="${3:-}"
  # shellcheck disable=SC2310
  if dir_exists "${_path}"; then
    log_info "Directory exists: ${_path}"
  else
    mkdir -p "${_path}"
    log_info "Created directory: ${_path}"
  fi
  chown "${_owner}:${_owner}" "${_path}"
  # shellcheck disable=SC2310
  if var_exists "${_mode}"; then
    chmod "${_mode}" "${_path}"
  fi
}

# Atomically write a config file with the right perms from start.
# Content from stdin -> tempfile in target dir -> perms -> rename
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
  local _path="${1:-}" _owner="${2:-root}" _mode="${3:-644}"
  local _dir _tmp
  _dir="$(dirname "${_path}")"

  # Make sure destination directory exists (don't override caller's perms on it)
  if ! dir_exists "${_dir}"; then
    mkdir -p "${_dir}"
  fi

  # Temp file in same directory so mv is atomic (same filesystem)
  _tmp=$(mktemp "${_path}.XXXXXX")

  # Restrictive umask during write — file never exists with open perms
  (umask 077 && cat >"${_tmp}")

  chown "${_owner}:${_owner}" "${_tmp}"
  chmod "${_mode}" "${_tmp}"
  mv "${_tmp}" "${_path}"

  # Self-verify: confirm the file actually made it and is non-empty
  # shellcheck disable=SC2310
  require_file "${_path}" "config" || return 1
  log_info "Wrote config: ${_path} (mode ${_mode}, owner ${_owner})"
}

fetch_file() {
  local _name="${1:-}"
  local _script_dir
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck disable=SC2310
  if file_exists "${_script_dir}/${_name}"; then
    cat "${_script_dir}/${_name}"
  elif curl -fsSL --max-time 10 "${_REPO_BASE_URL_}${_name}" 2>/dev/null; then
    : # curl already wrote to stdout
  else
    return 1
  fi
}

# TODO
# If we download file, I'd like to do checksum validation
check_integrity() {
  :
}

render_template() {
  local _content=""
  local _kv=""
  local _key=""
  local _val=""

  _content="$(cat)"

  for _kv in "${@}"; do
    _key="${_kv%%=*}"
    _val="${_kv#*=}"
    _content="${_content//\{\{${_key}\}\}/${_val}}"
    _content="${_content//\$\{${_key}\}/${_val}}"
  done

  printf "%s\n" "${_content}"
}

json_escape() {
  local _value="${1:-}"
  _value="${_value//\\/\\\\}"
  _value="${_value//\"/\\\"}"
  _value="${_value//$'\n'/\\n}"
  printf "%s" "${_value}"
}
### Ephemeral config file server ##############################################

setup_config_server() {
  log_info "Config server starting (port ${_CONFIG_SERVE_PORT_}, ${_CONFIG_SERVE_HOURS_}h TTL)..."

  # Stop existing server if running from a previous install
  if systemctl is-active --quiet gns3-config-serve.service 2>/dev/null; then
    systemctl stop gns3-config-serve.service 2>/dev/null || true
    systemctl stop gns3-config-serve-stop.timer 2>/dev/null || true
    log_info "Stopped previous config server"
  fi

  # Clean previous serve directory (public-facing only)
  # shellcheck disable=SC2310
  if dir_exists "${_CONFIG_SERVE_DIR_}"; then
    rm -rf "${_CONFIG_SERVE_DIR_}"
  fi

  # Ensure deploy directory exists for secrets
  ensure_directory "${_DEPLOY_DIR_}" root 700

  # Persist slug across re-runs so URL stays stable
  local _serve_slug
  # shellcheck disable=SC2310
  if file_exists "${_DEPLOY_DIR_}/serve_slug"; then
    _serve_slug=$(cat "${_DEPLOY_DIR_}/serve_slug")
    log_info "Reusing existing serve slug: ${_serve_slug}"
  else
    _serve_slug=$(openssl rand -hex 3)
    echo "${_serve_slug}" >"${_DEPLOY_DIR_}/serve_slug"
    chmod 600 "${_DEPLOY_DIR_}/serve_slug"
  fi

  local _serve_path="${_CONFIG_SERVE_DIR_}/${_serve_slug}"
  mkdir -p "${_serve_path}"
  log_info "Config serve path: ${_serve_path}"

  local _lan_ip _public_ip _gns3_bin _gns3_ver
  _lan_ip="${SERVER_PRIVATE_IP}"
  _public_ip="${SERVER_PUBLIC_IP}"

  _gns3_bin="/usr/bin/gns3server"
  if [[ -x "${_GNS3_VENV_}/bin/gns3server" ]]; then
    _gns3_bin="${_GNS3_VENV_}/bin/gns3server"
  fi

  # Extract exact semantic version, fallback to "unknown"
  _gns3_ver=$("${_gns3_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
  if [[ -z "${_gns3_ver}" ]]; then
    _gns3_ver="unknown"
  fi

  # VPN config files (encrypted by default)
  local _conf_passphrase=""

  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    # Fatal if we can't determine public IP for VPN configs
    if [[ "${_public_ip}" == "UNKNOWN" ]]; then
      log_fatal "Couldn't find public IP. VPN configs need a reachable IP."
    fi

    if [[ "${UNSAFE_CONFIGS}" -eq 0 ]]; then
      # Persist passphrase across re-runs
      # shellcheck disable=SC2310
      if file_exists "${_DEPLOY_DIR_}/passphrase"; then
        _conf_passphrase=$(cat "${_DEPLOY_DIR_}/passphrase")
        log_info "Reusing existing config passphrase"
      else
        _conf_passphrase=$(generate_passphrase)
        echo "${_conf_passphrase}" >"${_DEPLOY_DIR_}/passphrase"
        chmod 600 "${_DEPLOY_DIR_}/passphrase"
      fi
    fi
  fi

  if [[ "${WITH_OPENVPN}" -eq 1 && -f /root/client.ovpn ]]; then
    if [[ "${UNSAFE_CONFIGS}" -eq 1 ]]; then
      cp /root/client.ovpn "${_serve_path}/o"
    else
      encrypted_copy /root/client.ovpn "${_serve_path}/o" "${_conf_passphrase}"
    fi
  fi

  if [[ ${WITH_WIREGUARD} -eq 1 && -f "${_WG_CONF_DIR_}/client1.conf" ]]; then
    if [[ "${UNSAFE_CONFIGS}" -eq 1 ]]; then
      cp "${_WG_CONF_DIR_}/client1.conf" "${_serve_path}/w"
    else
      encrypted_copy "${_WG_CONF_DIR_}/client1.conf" "${_serve_path}/w" "${_conf_passphrase}"
    fi
  fi

  # Also stash client configs in deploy dir for safekeeping
  # shellcheck disable=SC2310
  if file_exists /root/client.ovpn; then
    cp /root/client.ovpn "${_DEPLOY_DIR_}/client.ovpn"
  fi
  # shellcheck disable=SC2310
  if file_exists "${_WG_CONF_DIR_}/client1.conf"; then
    cp "${_WG_CONF_DIR_}/client1.conf" "${_DEPLOY_DIR_}/wg-client1.conf"
  fi

  # ## Landing page ##########################################################

  log_info "Rendering UI template..."

  local _template_dst="${_CONFIG_SERVE_DIR_}/index.html"
  local _warnings_json="[]"
  local _w=""

  if [[ "${#WARN_MESSAGES[@]}" -gt 0 ]]; then
    _warnings_json="["
    for _w in "${WARN_MESSAGES[@]}"; do
      _warnings_json+="\"$(json_escape "${_w}")\","
    done
    _warnings_json="${_warnings_json%,}]"
  fi

  # shellcheck disable=SC2310
  if fetch_file "${_REPO_LANDING_HTML_}" | render_template \
    "LAN_IP=${_lan_ip}" \
    "PUBLIC_IP=${_public_ip}" \
    "HOSTNAME=${SERVER_HOSTNAME}" \
    "GNS3_VERSION=${_gns3_ver}" \
    "GNS3_PORT=${_GNS3_PORT_}" \
    "WITH_OPENVPN=${WITH_OPENVPN}" \
    "WITH_WIREGUARD=${WITH_WIREGUARD}" \
    "WITH_DOCKER=${WITH_DOCKER}" \
    "DISABLE_KVM=${DISABLE_KVM}" \
    "UNSAFE_CONFIGS=${UNSAFE_CONFIGS}" \
    "SERVE_SLUG=${_serve_slug}" \
    "SERVE_HOURS=${_CONFIG_SERVE_HOURS_}" \
    "SERVE_PORT=${_CONFIG_SERVE_PORT_}" \
    "WARNINGS_JSON=${_warnings_json}" \
    "_OVPN_PORT_=${_OVPN_PORT_}" \
    "_WG_PORT_=${_WG_PORT_}" | ensure_config "${_template_dst}" root 644; then
    log_ok "Landing page generated"
  else
    log_error "Failed to obtain template. Using basic fallback UI."
    printf "%s\n" \
      "<html><head><title>GNS3 Config Server</title></head>" \
      "<body><h1>GNS3 Config Server</h1>" \
      "<p>Template missing. Check console for details.</p></body></html>" |
      ensure_config "${_template_dst}" root 644
  fi

  # ## Systemd units ##########################################################

  fetch_file "${_TEMPLATE_CONFIG_SERVE_SERVICE_}" | render_template \
    "_CONFIG_SERVE_DIR_=${_CONFIG_SERVE_DIR_}" \
    "_CONFIG_SERVE_PORT_=${_CONFIG_SERVE_PORT_}" |
    ensure_config /etc/systemd/system/gns3-config-serve.service root 644

  fetch_file "${_TEMPLATE_CONFIG_SERVE_TIMER_}" | render_template \
    "_CONFIG_SERVE_HOURS_=${_CONFIG_SERVE_HOURS_}" |
    ensure_config /etc/systemd/system/gns3-config-serve-stop.timer root 644

  fetch_file "${_TEMPLATE_CONFIG_SERVE_STOP_SERVICE_}" | render_template \
    "_CONFIG_SERVE_DIR_=${_CONFIG_SERVE_DIR_}" \
    "_CONFIG_SERVE_PORT_=${_CONFIG_SERVE_PORT_}" |
    ensure_config /etc/systemd/system/gns3-config-serve-stop.service root 644

  enable_and_start gns3-config-serve.service
  enable_and_start gns3-config-serve-stop.timer

  log_ok "Config server live on port ${_CONFIG_SERVE_PORT_} (auto-stops in ${_CONFIG_SERVE_HOURS_}h)"

  # MOTD
  fetch_file "${_TEMPLATE_MOTD_}" | render_template \
    "_lan_ip=${_lan_ip}" \
    "_CONFIG_SERVE_PORT_=${_CONFIG_SERVE_PORT_}" |
    ensure_config /etc/update-motd.d/70-gns3-vpn root 755
}

### Firewall (ufw) ##########################################################

configure_firewall() {
  if [[ "${DISABLE_FIREWALL}" -eq 1 ]]; then
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

  if [[ "${#_local_subnets[@]}" -gt 0 ]]; then
    log_info "RFC1918 subnets detected: ${_local_subnets[*]}"
  fi

  for _port in "${REQUIRED_PORTS[@]}"; do
    local _status="PERM"

    case "${_port}" in
      "${_OVPN_PORT_}" | "${_WG_PORT_}")
        # VPN ports: open from anywhere, both TCP and UDP
        ufw allow "${_port}"/tcp comment "GNS3 - ${_status} (VPN)" >/dev/null 2>&1
        ufw allow "${_port}"/udp comment "GNS3 - ${_status} (VPN)" >/dev/null 2>&1
        ;;
      "${_CONFIG_SERVE_PORT_}")
        _status="CLEAR"
        ufw allow "${_port}"/tcp comment "GNS3 - ${_status} (ephem. webserver)" >/dev/null 2>&1
        ;;
      *)
        # Non-VPN ports: scope to SSH source and local subnets
        if [[ -n "${_remote_ssh_ip}" ]]; then
          ufw allow from "${_remote_ssh_ip}" to any port "${_port}" proto tcp \
            comment "GNS3 - ${_status}" >/dev/null 2>&1
        fi
        for _subnet in "${_local_subnets[@]}"; do
          ufw allow from "${_subnet}" to any port "${_port}" proto tcp \
            comment "GNS3 - ${_status}" >/dev/null 2>&1
        done
        ;;
    esac
  done

  # Enable forwarding in ufw if any VPN is configured
  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    local _ufw_default="/etc/default/ufw"
    # shellcheck disable=SC2310
    if file_exists "${_ufw_default}"; then
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
  mkdir -p "${_GNS3_HOME_}"/{images,projects,appliances,configs}

  if ! id "${_GNS3_USER_}" &>/dev/null; then
    local _groups_csv
    printf -v _groups_csv '%s,' "${REQUIRED_GROUPS[@]}"
    _groups_csv="${_groups_csv%,}"

    useradd --system \
      --home-dir "${_GNS3_HOME_}" \
      --no-create-home \
      --comment "GNS3 server" \
      --groups "${_groups_csv}" \
      --shell /usr/sbin/nologin \
      "${_GNS3_USER_}"
    log_ok "Created user ${_GNS3_USER_}"
  else
    for _grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "${_grp}" "${_GNS3_USER_}"
    done
    log_ok "User ${_GNS3_USER_} already exists — updated groups"
  fi

  chown -R "${_GNS3_USER_}:${_GNS3_USER_}" "${_GNS3_HOME_}"
}

propagate_groups_to_invoker() {
  local _invoker
  _invoker=$(detect_invoking_user)
  if [[ -n ${_invoker} ]]; then
    log_info "Adding ${_invoker} to groups: ${REQUIRED_GROUPS[*]}"
    for _grp in "${REQUIRED_GROUPS[@]}"; do
      usermod -aG "${_grp}" "${_invoker}"
    done
    log_ok "Group membership updated for ${_invoker} (log out/in to take effect)"
  fi
}

# Is repo present? Handles old deb and new deb822 URIs: format
gns3_repo_present() {
  grep -rEq \
    "^(deb|URIs:)[[:space:]].*ppa\.launchpadcontent\.net/gns3/${REPOSITORY}" \
    /etc/apt/sources.list.d/ 2>/dev/null
}

# Add gns3 repo (if not already present)
add_gns3_repository() {
  # shellcheck disable=SC2310
  if gns3_repo_present; then
    log_info "GNS3 PPA already configured"
    return
  fi
  log_info "Adding GNS3 PPA: ppa:gns3/${REPOSITORY}"
  apt-add-repository -y "ppa:gns3/${REPOSITORY}" >/dev/null
  log_ok "GNS3 repository added"
}

# Add Docker repo
add_docker_repository() {
  # shellcheck disable=SC2310
  if file_exists "${_DOCKER_KEYRING_}"; then
    log_info "Docker GPG key already present — skipping download"
  else
    log_info "Adding Docker CE repository..."
    install -m 0755 -d /etc/apt/keyrings

    # shellcheck disable=SC2310
    if ! fetch_file "${_REPO_DOCKER_GPG_}" > "${_DOCKER_KEYRING_}"; then
      log_fatal "Could not obtain Docker GPG key from any source."
    fi

    # Sanity check — make sure we got an actual key, not an error page
    # shellcheck disable=SC2310
    if ! file "${_DOCKER_KEYRING_}" 2>/dev/null | grep -qiE 'pgp|openpgp|gpg'; then
      log_warn_sticky "Docker keyring file may not be a valid GPG key. Check: ${_DOCKER_KEYRING_}"
    fi

    chmod a+r "${_DOCKER_KEYRING_}"
  fi

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${_DOCKER_KEYRING_}] ${_DOCKER_BASE_URL_} ${OS_CODENAME} stable
EOF
  log_ok "Docker repository configured"
}

# Do we need to run install?
needs_install() {
  local _pkg
  for _pkg in "${REQUIRED_PKGS[@]}"; do
    # dpkg-query is faster than apt-cache for this
    # shellcheck disable=SC2310
    if ! dpkg-query -W -f='${Status}' "${_pkg}" 2>/dev/null | grep -q "install ok installed"; then
      return 0 # at least one package needs install
    fi
  done
  return 1 # everything installed
}

# Updates, ugprades, and installs - quietly
install_packages() {
  apt_retry update -qq

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
  if [[ "${DISABLE_KVM}" -eq 1 ]]; then
    _hw_accel="False"
    log_warn "KVM disabled — Qemu performance will be degraded"
  fi

  ensure_directory "${_GNS3_CONF_DIR_}" "${_GNS3_USER_}" 700
  # shellcheck disable=SC2310
  fetch_file "${_TEMPLATE_GNS3_SERVER_CONF_}" | render_template \
    "_DEPLOY_MARKER_=${_DEPLOY_MARKER_}" \
    "_listen_host=${_listen_host}" \
    "_GNS3_PORT_=${_GNS3_PORT_}" \
    "_GNS3_HOME_=${_GNS3_HOME_}" \
    "_hw_accel=${_hw_accel}" |
    ensure_config "${_GNS3_CONF_DIR_}/gns3_server.conf" "${_GNS3_USER_}" 600

  log_ok "GNS3 configuration written"
}

### Systemd service #############################################

install_gns3_service() {
  log_info "Installing GNS3 systemd service..."

  local _gns3_bin="/usr/bin/gns3server"
  if [[ -x "${_GNS3_VENV_}/bin/gns3server" ]]; then
    _gns3_bin="${_GNS3_VENV_}/bin/gns3server"
    log_info "Using venv binary: ${_gns3_bin}"
  fi

  fetch_file "${_TEMPLATE_GNS3_SERVICE_}" | render_template \
    "GNS3_USER=${_GNS3_USER_}" \
    "_gns3_bin=${_gns3_bin}" |
    ensure_config "${_GNS3_SERVICE_FILE_}" root 644

  enable_and_start gns3
  log_ok "GNS3 service installed and enabled"
}

### OpenVPN setup ################################################

configure_openvpn() {
  log_info "Configuring OpenVPN..."

  local _public_ip="${SERVER_PUBLIC_IP}"
  if [[ "${_public_ip}" == "UNKNOWN" ]]; then
    log_fatal "Could not determine public IP for OpenVPN configuration."
  fi

  log_info "Public IP detected: ${_public_ip}"

  log_info "Generating OpenVPN keys..."
  ensure_directory "${_OVPN_CONF_DIR_}" root 755

  # If using *RSA*
  if [[ "${USE_LEGACY_RSA}" -eq 1 ]]; then
    log_info "Using legacy RSA crypto (DH params may take a minute)..."
    # shellcheck disable=SC2310
    if file_exists "${_OVPN_CONF_DIR_}/dh.pem"; then
      log_info "Already have DH params. Skipping."
    else
      openssl dhparam -quiet 2048 | ensure_config "${_OVPN_CONF_DIR_}/dh.pem" root 600
    fi
    # shellcheck disable=SC2310
    require_file "${_OVPN_CONF_DIR_}/dh.pem" "OpenVPN DH params" || log_fatal "DH param generation failed"

    # shellcheck disable=SC2310
    if file_exists "${_OVPN_CONF_DIR_}/key.pem"; then
      log_info "Already have OpenVPN key. Skipping."
    else
      openssl genrsa 2048 | ensure_config "${_OVPN_CONF_DIR_}/key.pem" root 600
    fi

  # If using *ECC*
  else
    log_info "Using elliptic curve crypto (P-384)..."
    # shellcheck disable=SC2310
    if file_exists "${_OVPN_CONF_DIR_}/key.pem"; then
      log_info "Already have OpenVPN key. Skipping."
    else
      openssl ecparam -name secp384r1 -genkey -noout | ensure_config "${_OVPN_CONF_DIR_}/key.pem" root 600
    fi

  fi
  # shellcheck disable=SC2310
  require_file "${_OVPN_CONF_DIR_}/key.pem" "OpenVPN private key" || log_fatal "Key generation failed"
  # shellcheck disable=SC2310
  if file_exists "${_OVPN_CONF_DIR_}/csr.pem"; then
    log_info "csr.pem already present."
  else
    openssl req -new -key "${_OVPN_CONF_DIR_}/key.pem" -out "${_OVPN_CONF_DIR_}/csr.pem" \
      -subj /CN=OpenVPN/ 2>/dev/null
  fi
  # shellcheck disable=SC2310
  require_file "${_OVPN_CONF_DIR_}/csr.pem" "OpenVPN CSR" || log_fatal "CSR generation failed"
  # shellcheck disable=SC2310
  if file_exists "${_OVPN_CONF_DIR_}/cert.pem"; then
    log_info "cert.pem already present."
  else
    openssl x509 -req -in "${_OVPN_CONF_DIR_}/csr.pem" -out "${_OVPN_CONF_DIR_}/cert.pem" \
      -signkey "${_OVPN_CONF_DIR_}/key.pem" -days 3650 &>/dev/null
  fi
  # shellcheck disable=SC2310
  require_file "${_OVPN_CONF_DIR_}/cert.pem" "OpenVPN certificate" || log_fatal "Certificate signing failed"

  local _dh_client_block=""
  local _dh_server_line="dh none"
  if [[ "${USE_LEGACY_RSA}" -eq 1 ]]; then
    _dh_client_block="<dh>$(cat "${_OVPN_CONF_DIR_}/dh.pem")</dh>"
    _dh_server_line="dh dh.pem"
  fi

  ensure_config /root/client.ovpn root 600 <<_EOF_OVPN_CLI
client
nobind
dev tun
<key>
$(cat "${_OVPN_CONF_DIR_}/key.pem")
</key>
<cert>
$(cat "${_OVPN_CONF_DIR_}/cert.pem")
</cert>
<ca>
$(cat "${_OVPN_CONF_DIR_}/cert.pem")
</ca>
${_dh_client_block}
<connection>
remote ${_public_ip} ${_OVPN_PORT_} udp
</connection>
_EOF_OVPN_CLI

  ensure_config "${_OVPN_CONF_DIR_}/udp${_OVPN_PORT_}.conf" root 644 <<_EOF_OVPN
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
port ${_OVPN_PORT_}
dev tun${_OVPN_PORT_}
status openvpn-status-${_OVPN_PORT_}.log
log-append /var/log/openvpn-udp${_OVPN_PORT_}.log
_EOF_OVPN
  # shellcheck disable=SC2310
  enable_and_start openvpn || true
  log_ok "OpenVPN configured"
}

### WireGuard setup #############################################

configure_wireguard() {
  log_info "Configuring WireGuard..."

  local _public_ip="${SERVER_PUBLIC_IP}"
  if [[ "${_public_ip}" == "UNKNOWN" ]]; then
    log_fatal "Could not determine public IP for WireGuard configuration."
  fi
  # shellcheck disable=SC2310
  ensure_directory "${_WG_CONF_DIR_}" root 700
  # shellcheck disable=SC2310
  if ! file_exists "${_WG_CONF_DIR_}/server.key"; then
    (
      umask 077
      wg genkey | tee "${_WG_CONF_DIR_}/server.key" | wg pubkey >"${_WG_CONF_DIR_}/server.pub"
    )
  fi
  # shellcheck disable=SC2310
  require_file "${_WG_CONF_DIR_}/server.key" "WireGuard server private key" || log_fatal "WG server keygen failed"
  # shellcheck disable=SC2310
  require_file "${_WG_CONF_DIR_}/server.pub" "WireGuard server public key" || log_fatal "WG server keygen failed"

  local _server_privkey _server_pubkey
  _server_privkey=$(cat "${_WG_CONF_DIR_}/server.key")
  _server_pubkey=$(cat "${_WG_CONF_DIR_}/server.pub")
  # shellcheck disable=SC2310
  if ! file_exists "${_WG_CONF_DIR_}/client1.key"; then
    (
      umask 077
      wg genkey | tee "${_WG_CONF_DIR_}/client1.key" | wg pubkey >"${_WG_CONF_DIR_}/client1.pub"
    )
  fi
  # shellcheck disable=SC2310
  require_file "${_WG_CONF_DIR_}/client1.key" "WireGuard client private key" || log_fatal "WG client keygen failed"

  local _client_privkey _client_pubkey
  _client_privkey=$(cat "${_WG_CONF_DIR_}/client1.key")
  _client_pubkey=$(cat "${_WG_CONF_DIR_}/client1.pub")

  local _default_iface
  _default_iface=$(ip route show default | awk '{print $5}' | head -1)
  if [[ -z "${_default_iface}" ]]; then
    _default_iface="eth0"
  fi

  # shellcheck disable=SC2310
  fetch_file "${_TEMPLATE_WG_SERVER_}" | render_template \
    "_WG_PORT_=${_WG_PORT_}" \
    "_server_privkey=${_server_privkey}" \
    "_default_iface=${_default_iface}" \
    "_client_pubkey=${_client_pubkey}" |
    ensure_config "${_WG_CONF_DIR_}/wg0.conf" root 600

  # shellcheck disable=SC2310
  fetch_file "${_TEMPLATE_WG_CLIENT_}" | render_template \
    "_client_privkey=${_client_privkey}" \
    "_server_pubkey=${_server_pubkey}" \
    "_public_ip=${_public_ip}" \
    "_WG_PORT_=${_WG_PORT_}" |
    ensure_config "${_WG_CONF_DIR_}/client1.conf" root 600

  # shellcheck disable=SC2310
  enable_and_start wg-quick@wg0 || true
  log_ok "WireGuard configured"
}

### Welcome setup ##############################################################

configure_welcome() {
  log_info "Setting up GNS3-VM welcome console..."

  ensure_config "/etc/sudoers.d/${_GNS3_USER_}" root 440 <<_EOF
${_GNS3_USER_}   ALL = (ALL) NOPASSWD: /usr/bin/apt-key
${_GNS3_USER_}   ALL = (ALL) NOPASSWD: /usr/bin/apt-get
${_GNS3_USER_}   ALL = (ALL) NOPASSWD: /usr/sbin/reboot
_EOF

  if ! visudo -cf "/etc/sudoers.d/${_GNS3_USER_}" &>/dev/null; then
    log_warn_sticky "sudoers fragment failed syntax check — removing"
    rm -f "/etc/sudoers.d/${_GNS3_USER_}"
  fi

  # shellcheck disable=SC2310
  if ! fetch_file "${_REPO_WELCOME_PY_}" > /usr/local/bin/welcome.py; then
    log_fatal "Could not obtain welcome.py from local resources or upstream."
  fi
  chmod 755 /usr/local/bin/welcome.py
  chown "${_GNS3_USER_}:${_GNS3_USER_}" /usr/local/bin/welcome.py

  mkdir -p /etc/systemd/system/getty@tty1.service.d
  ensure_config "/etc/systemd/system/getty@tty1.service.d/override.conf" root 644 <<_EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${_GNS3_USER_} --noclear %I \$TERM
_EOF

  if ! grep -q 'welcome.py' "${_GNS3_HOME_}/.bashrc" 2>/dev/null; then
    echo "python3 /usr/local/bin/welcome.py" >>"${_GNS3_HOME_}/.bashrc"
  fi

  echo "${_GNS3_USER_}:gns3" | chpasswd
  usermod --shell /bin/bash "${_GNS3_USER_}"
  usermod -aG sudo "${_GNS3_USER_}"

  log_ok "Welcome console configured"
}

### Start services ##########################################################

start_services() {
  log_info "Verifying services..."
  sleep 2

  if systemctl is-active --quiet gns3; then
    log_ok "GNS3 service running"
  else
    log_warn_sticky "GNS3 service failed to start"
    log_warn_sticky "  Check logs: journalctl -u gns3 --no-pager -n 20"
  fi

  if [[ "${WITH_DOCKER}" -eq 1 ]]; then
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
  local _url="${1:-}" _desc="${2:-}"
  if curl -sf --max-time 5 "${_url}" &>/dev/null; then
    log_ok "${_desc} responding: ${_url}"
    return 0
  fi
  log_warn_sticky "${_desc} not responding: ${_url}"
  return 1
}

# Helper: check if a TCP (default) or UDP port is listening
probe_port_listening() {
  local _port="${1:-}" _desc="${2:-}" _proto="${3:-tcp}"
  local _flag="-tlnH"

  if [[ "${_proto}" == "udp" ]]; then
    _flag="-ulnH"
  fi
  if ss "${_flag}" 2>/dev/null | grep -q ":${_port} "; then
    log_ok "${_desc} listening on ${_proto} port ${_port}"
    return 0
  fi
  log_warn_sticky "${_desc} not listening on ${_proto} port ${_port}"
  return 1
}

validate() {
  log_info "Running post-install validation..."
  local _lan_ip _serve_slug
  _lan_ip="${SERVER_PRIVATE_IP}"

  sleep 3

  # GNS3 API responding
  # shellcheck disable=SC2310
  if ! probe_http "http://${_lan_ip}:${_GNS3_PORT_}/v2/version" "GNS3 API"; then
    probe_http "http://localhost:${_GNS3_PORT_}/v2/version" "GNS3 API (localhost fallback)" ||
      log_warn_sticky "  Check: journalctl -u gns3 --no-pager -n 20"
  fi

  # Port listening checks
  # shellcheck disable=SC2310
  probe_port_listening "${_GNS3_PORT_}" "GNS3 server" || true
  # shellcheck disable=SC2310
  probe_port_listening "${_CONFIG_SERVE_PORT_}" "Config server" || true

  # Config server landing page
  # shellcheck disable=SC2310
  probe_http "http://${_lan_ip}:${_CONFIG_SERVE_PORT_}/" "Landing page" || true

  # VPN config downloadable through the slug path
  # shellcheck disable=SC2310
  if file_exists "${_DEPLOY_DIR_}/serve_slug"; then
    _serve_slug=$(cat "${_DEPLOY_DIR_}/serve_slug")
    if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
      # shellcheck disable=SC2310
      probe_http "http://${_lan_ip}:${_CONFIG_SERVE_PORT_}/${_serve_slug}/w" "WireGuard config download" || true
    fi
    if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
      # shellcheck disable=SC2310
      probe_http "http://${_lan_ip}:${_CONFIG_SERVE_PORT_}/${_serve_slug}/o" "OpenVPN config download" || true
    fi
  fi

  # VPN tunnel interfaces
  if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
    # shellcheck disable=SC2310
    probe_port_listening "${_WG_PORT_}" "WireGuard" udp || true
    if ip link show wg0 &>/dev/null; then
      log_ok "WireGuard interface wg0 is up"
    else
      log_warn_sticky "WireGuard interface wg0 not found"
    fi
  fi

  if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
    if ip link show "tun${_OVPN_PORT_}" &>/dev/null; then
      log_ok "OpenVPN interface tun${_OVPN_PORT_} is up"
    else
      log_warn_sticky "OpenVPN interface tun${_OVPN_PORT_} not found"
    fi
  fi

  # Config server auto-stop timer armed
  if systemctl list-timers --all 2>/dev/null | grep -q "gns3-config-serve-stop"; then
    log_ok "Config server auto-stop timer armed"
  else
    log_warn_sticky "Config server auto-stop timer NOT armed — server will not expire on schedule"
  fi

  # Sysctl hardening applied
  # shellcheck disable=SC2310
  if file_exists /etc/sysctl.d/90-gns3-hardening.conf; then
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
  # shellcheck disable=SC2310
  if dir_exists "${_DEPLOY_DIR_}"; then
    local _mode
    _mode=$(stat -c %a "${_DEPLOY_DIR_}" 2>/dev/null)
    if [[ "${_mode}" == "700" ]]; then
      log_ok "Deploy directory permissions: 700"
    else
      log_warn_sticky "Deploy directory permissions are ${_mode}, expected 700"
    fi
  fi

  # Docker
  if [[ "${WITH_DOCKER}" -eq 1 ]]; then
    if docker info &>/dev/null; then
      log_ok "Docker engine responding"
    else
      log_warn_sticky "Docker installed but not responding"
    fi
  fi

  # GNS3 binary sanity
  local _gns3_bin="/usr/bin/gns3server"
  if [[ -x "${_GNS3_VENV_}/bin/gns3server" ]]; then
    _gns3_bin="${_GNS3_VENV_}/bin/gns3server"
  fi
  if "${_gns3_bin}" --version &>/dev/null; then
    log_ok "gns3server binary: $("${_gns3_bin}" --version 2>&1 | head -1)"
  else
    log_warn_sticky "gns3server binary cannot execute — possible Python venv issue"
    log_warn_sticky "  Binary: ${_gns3_bin}"
    log_warn_sticky "  Check:  ${_gns3_bin} --version"
  fi

  # UFW active when firewall configuration was attempted
  if [[ "${DISABLE_FIREWALL}" -eq 0 ]] && command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      log_ok "UFW active"
    else
      log_warn_sticky "UFW is installed but not active — no firewall rules enforced"
    fi
  fi

  if [[ "${#WARN_MESSAGES[@]}" -eq 0 ]]; then
    log_ok "All post-install checks passed"
  fi
}

### Summary banner ##########################################################

print_summary() {
  local _lan_ip _public_ip
  _lan_ip="${SERVER_PRIVATE_IP}"
  _public_ip="${SERVER_PUBLIC_IP}"

  echo ""
  printf "${_GREEN_}${_BOLD_}  GNS3 Server Install Complete${_RST_}\n"
  printf "  ##################################\n\n"
  printf "  Server: http://%s:%s\n" "${_lan_ip}" "${_GNS3_PORT_}"
  printf "  Config: %s/gns3_server.conf\n" "${_GNS3_CONF_DIR_}"
  printf "  Data:   %s/\n" "${_GNS3_HOME_}"
  echo "  Logs:   /var/log/gns3/gns3.log"
  echo "  Status: systemctl status gns3"
  echo ""

  if [[ ${WITH_OPENVPN} -eq 1 || ${WITH_WIREGUARD} -eq 1 ]]; then
    echo "  VPN"
    echo "  ##################################"

    if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
      printf "  WireGuard: %s:%s\n" "${_public_ip}" "${_WG_PORT_}"
      printf "    Tunnel:  172.16.254.1:%s\n" "${_GNS3_PORT_}"
    fi

    if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
      printf "  OpenVPN:   %s:%s/udp\n" "${_public_ip}" "${_OVPN_PORT_}"
      printf "    Tunnel:  172.16.253.1:%s\n" "${_GNS3_PORT_}"
    fi
    echo ""
  fi

  # Config server info
  # shellcheck disable=SC2310
  if file_exists "${_DEPLOY_DIR_}/serve_slug"; then
    local _serve_slug
    _serve_slug=$(cat "${_DEPLOY_DIR_}/serve_slug")
    printf "  Landing page:\n"
    printf "  http://%s:%s/\n" "${_lan_ip}" "${_CONFIG_SERVE_PORT_}"
    # shellcheck disable=SC2059
    printf "  ${_YELLOW_}Expires in %sh${_RST_}\n\n" "${_CONFIG_SERVE_HOURS_}"
  fi

  # Encrypted config download commands
  # shellcheck disable=SC2310
  if file_exists "${_DEPLOY_DIR_}/passphrase"; then
    local _pass _serve_slug
    _pass=$(cat "${_DEPLOY_DIR_}/passphrase")
    _serve_slug=$(cat "${_DEPLOY_DIR_}/serve_slug")

    echo "  Secure config download"
    echo "  ##################################"

    if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
      # shellcheck disable=SC2059
      printf "  ${_CYAN_}WireGuard:${_RST_}\n"
      echo "  curl -s http://${_lan_ip}:${_CONFIG_SERVE_PORT_}/${_serve_slug}/w | openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:${_pass} -a > wg.conf"
      echo ""
    fi

    if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
      # shellcheck disable=SC2059
      printf "  ${_CYAN_}OpenVPN:${_RST_}\n"
      echo "  curl -s http://${_lan_ip}:${_CONFIG_SERVE_PORT_}/${_serve_slug}/o | openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:${_pass} -a > conf.ovpn"
      echo ""
    fi
  fi

  if [[ "${DISABLE_KVM}" -eq 1 ]]; then
    # shellcheck disable=SC2059
    printf "  ${_YELLOW_}KVM: DISABLED${_RST_}\n"
    echo ""
  fi

  local _invoker
  _invoker=$(detect_invoking_user)
  # shellcheck disable=SC2310
  if var_exists "${_invoker}"; then
    # shellcheck disable=SC2059
    printf "  ${_CYAN_}Log out/in as ${_invoker}${_RST_}"
    echo " for group changes"
    echo ""
  fi

  if [[ "${#WARN_MESSAGES[@]}" -gt 0 ]]; then
    # shellcheck disable=SC2059
    printf "  ${_YELLOW_}${_BOLD_}Action Required${_RST_}\n"
    echo "  ##################################"
    for _warning in "${WARN_MESSAGES[@]}"; do
      # shellcheck disable=SC2059
      printf "  ${_YELLOW_}!${_RST_} %s\n" "${_warning}"
    done
    echo ""
  fi
}

##############################################################################
# MAIN
##############################################################################

main() {
  export DEBIAN_FRONTEND="noninteractive"

  parse_args "${@}"
  apply_option_flags

# shellcheck disable=SC2310
  if ! is_root; then
    log_fatal "Must run as root. Try: sudo ${0}"
  fi

  # Ensure exclusive execution
  exec 9>/var/lock/gns3-install.lock
  if ! flock -n 9; then
    log_fatal "Another instance of this script is already running."
  fi

  log_info "Bootstrapping essential packages..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq curl software-properties-common >/dev/null 2>&1
  log_ok "Bootstrap complete"

  set -E

  trap 'on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
  trap 'log_warn "Interrupted by user."; exit 130' INT TERM

  # Initialize deploy directory for secrets and state
  ensure_directory "${_DEPLOY_DIR_}" root 700

  # Log everything to file for post-mortem
  exec > >(tee -a "${_DEPLOY_DIR_}/install.log") 2>&1

  preflight_checks
  readonly SERVER_PRIVATE_IP=$(get_lan_ip)
  readonly SERVER_PUBLIC_IP=$(get_public_ip)
  readonly SERVER_HOSTNAME=$(hostname)
  readonly OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"

  # # Phase 1: Repositories ##################################################

  add_gns3_repository
  if [[ "${WITH_DOCKER}" -eq 1 ]]; then
    add_docker_repository
  fi

  # # Phase 2: Packages (single apt pass) ####################################

  install_packages

  # # Phase 3: Users and groups ##############################################

  setup_groups
  setup_gns3_user
  propagate_groups_to_invoker

  # # Phase 4: Configuration ################################################

  configure_gns3
  install_gns3_service

  if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
    configure_openvpn
  fi
  if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
    configure_wireguard
  fi
  if [[ "${WITH_WELCOME}" -eq 1 ]]; then
    configure_welcome
  fi
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

  if [[ "${WITH_WELCOME}" -eq 1 ]]; then
    python3 -c 'import sys; sys.path.append("/usr/local/bin/"); import welcome; ws = welcome.Welcome_dialog(); ws.repair_remote_install()' || true
  fi

  # ## Done ####################################################################

  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
