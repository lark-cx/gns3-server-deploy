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
#   --unsafe-configs          Serve VPN configs unencrypted (not recommended)
#   --unstable                Use GNS3 unstable PPA
#   --custom-repository REPO  Use a custom GNS3 PPA name
#   -h, --help                Show this help

#  Constants ################################################################

readonly REPO_BASE_URL="https://raw.githubusercontent.com/lark-cx/gns3-server-deploy/refs/heads/main/"
readonly REPO_LANDING_HTML="template.html"
readonly DOCKER_BASE_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly GNS3_USER="gns3"
readonly GNS3_HOME="/opt/gns3"
readonly GNS3_CONF_DIR="/etc/gns3"
readonly GNS3_SERVICE_FILE="/lib/systemd/system/gns3.service"
readonly GNS3_VENV="/usr/share/gns3/gns3-server"
readonly CONFIG_SERVE_PORT=8003
readonly CONFIG_SERVE_DIR="/var/lib/gns3-config-serve"
readonly CONFIG_SERVE_HOURS=2
readonly DEPLOY_MARKER="# deployed by gns3-remote-install-redux"

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
is_root() { [[ "${EUID}" -eq 0 ]]; }

# Sticky warnings — collected throughout execution, displayed before summary
WARNINGS=()
log_warn_sticky() {
	log_warn "$1"
	WARNINGS+=("$1")
}

### Mutable arrays (built up by option flags) ##############################─

REQUIRED_CMDS=(apt apt-add-repository dpkg chown chmod useradd usermod lsmod systemctl ss openssl)
REQUIRED_PORTS=(3080)
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
  --unsafe-configs          Serve VPN configs unencrypted
  --unstable                Use the GNS3 unstable PPA
  --custom-repository REPO  Use a custom GNS3 PPA name
  -h, --help                Show this help
EOF
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

if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
	REQUIRED_PORTS+=(1194)
	REQUIRED_PKGS+=("${PKGS_OPENVPN[@]}")
fi

if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
	REQUIRED_PORTS+=(51820)
	REQUIRED_MODS+=(wireguard)
	REQUIRED_PKGS+=("${PKGS_WIREGUARD[@]}")
fi

# Config server port always needed (landing page is default-on)
REQUIRED_PORTS+=("${CONFIG_SERVE_PORT}")

if [[ "${WITH_DOCKER}" -eq 1 ]]; then
	REQUIRED_PKGS+=("${PKGS_DOCKER[@]}")
	REQUIRED_GROUPS+=(docker)
fi

if [[ "${WITH_WELCOME}" -eq 1 ]]; then
	REQUIRED_PKGS+=("${PKGS_WELCOME[@]}")
fi

### Preflight checks ########################################################

preflight_checks() {
	local _has_errors=0

	if [[ ! "${OSTYPE}" == linux-gnu* ]]; then
		log_fatal "This script requires Linux (detected: ${OSTYPE})."
	fi

	if [[ -f /etc/os-release ]]; then
		source /etc/os-release
	else
		log_fatal "/etc/os-release not found. Is this Ubuntu?"
	fi

	if [[ "${ID:-}" != "ubuntu" ]]; then
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
			if [[ "${_mod}" == "kvm" && "${DISABLE_KVM}" -eq 1 ]]; then
				continue
			fi
			log_info "Loading kernel module: $_mod"
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
	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		echo "${SUDO_USER}"
	fi
}

# Get public IP with fallback chain (dig → curl → UNKNOWN)
get_public_ip() {
	local _ip
	_ip=$(dig @ns1.google.com -t txt o-o.myaddr.l.google.com +short -4 2>/dev/null | sed 's/"//g')
	if [[ -n "${_ip}" ]]; then
		echo "${_ip}"
		return
	fi
	_ip=$(curl -sf --max-time 5 https://icanhazip.com 2>/dev/null)
	if [[ -n "${_ip}" ]]; then
		echo "${_ip}"
		return
	fi
	_ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)
	if [[ -n "${_ip}" ]]; then
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
	local _chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local _nums="0123456789"
	printf "%s-%s-%s" \
		"$(LC_ALL=C tr -dc "${_chars}" </dev/urandom | head -c 4)" \
		"$(LC_ALL=C tr -dc "${_chars}" </dev/urandom | head -c 4)" \
		"$(LC_ALL=C tr -dc "${_nums}" </dev/urandom | head -c 4)"
}

# Encrypt a file with a passphrase, output .enc alongside original
encrypted_copy() {
	local _src="$1" _dst="$2" _pass="$3"
	openssl enc -aes-256-cbc -pbkdf2 -iter 15000 -salt \
		-pass "pass:${_pass}" -a \
		-in "${_src}" -out "${_dst}"
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

### Ephemeral config file server ##############################################

setup_config_server() {
	log_info "Setting up config server (port ${CONFIG_SERVE_PORT}, ${CONFIG_SERVE_HOURS}h TTL)..."

	# Stop existing server if running from a previous install
	if [[ "$(systemctl is-active gns3-config-serve.service)" == "active" ]]; then
		systemctl stop gns3-config-serve.service 2>/dev/null || true
		systemctl stop gns3-config-serve-stop.timer 2>/dev/null || true
	else
		log_info "gns3 config server not active"
	fi

	[[ -d "${CONFIG_SERVE_DIR}" ]] && rm -rf "${CONFIG_SERVE_DIR}" && log_info "Removed config server directory" || log_info "No config server directory"

	local _serve_slug _serve_path _lan_ip _public_ip _gns3_bin _gns3_ver
	_serve_slug=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
	_serve_path="${CONFIG_SERVE_DIR}/${_serve_slug}"
	log_info "Creating config server directory: ${_serve_path}"
	mkdir -p "${_serve_path}"

	echo "${_serve_slug}" >"${CONFIG_SERVE_DIR}/.serve_slug"
	log_info "${_serve_path} ${_serve_slug}"
	_lan_ip=$(get_lan_ip)
	_public_ip=$(get_public_ip)
	_gns3_bin="/usr/bin/gns3server"
	[[ -x "${GNS3_VENV}/bin/gns3server" ]] && _gns3_bin="${GNS3_VENV}/bin/gns3server"

	# Extract exact semantic version, fallback to "unknown"
	_gns3_ver=$("${_gns3_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	[[ -z "${_gns3_ver}" ]] && _gns3_ver="unknown"

	# ## VPN config files (encrypted by default) ################################
	local _conf_passphrase=""
	local _has_vpn_configs=0

	if [[ "${WITH_OPENVPN}" -eq 1 || "${WITH_WIREGUARD}" -eq 1 ]]; then
		# Fatal if we can't determine public IP for VPN configs
		if [[ "${_public_ip}" == "UNKNOWN" ]]; then
			log_fatal "Could not determine public IP — VPN configs require a reachable address."
		fi

		if [[ "${UNSAFE_CONFIGS}" -eq 0 ]]; then
			_conf_passphrase=$(generate_passphrase)
		fi
	fi

	if [[ "${WITH_OPENVPN}" -eq 1 && -f /root/client.ovpn ]]; then
		_has_vpn_configs=1
		if [[ "${UNSAFE_CONFIGS}" -eq 1 ]]; then
			cp /root/client.ovpn "${_serve_path}/$(hostname).ovpn"
		else
			encrypted_copy /root/client.ovpn "${_serve_path}/$(hostname).ovpn.enc" "${_conf_passphrase}"
		fi
	fi

	if [[ "${WITH_WIREGUARD}" -eq 1 && -f /etc/wireguard/client1.conf ]]; then
		_has_vpn_configs=1
		if [[ "${UNSAFE_CONFIGS}" -eq 1 ]]; then
			cp /etc/wireguard/client1.conf "${_serve_path}/wg-client1.conf"
		else
			encrypted_copy /etc/wireguard/client1.conf "${_serve_path}/wg-client1.conf.enc" "${_conf_passphrase}"
		fi
	fi

	# Stash passphrase for summary banner
	if [[ -n "${_conf_passphrase}" ]]; then
		echo "${_conf_passphrase}" >"${CONFIG_SERVE_DIR}/.passphrase"
		chmod 600 "${CONFIG_SERVE_DIR}/.passphrase"
	fi

	# ## Landing page ##########################################################

	log_info "Fetching UI template..."

	local _script_dir _template_src _template_dst _template_ok
	_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
	_template_src="${_script_dir}/${REPO_LANDING_HTML}"
	_template_dst="${CONFIG_SERVE_DIR}/index.html"
	_template_ok=0

	# 1. Try local file
	if [[ -f "${_template_src}" ]]; then
		log_info "Using local template: ${_template_src}"
		cp "${_template_src}" "${_template_dst}" && _template_ok=1
	else
		log_warn "Local template not found. Attempting to download from repo..."
		# 2. Try curl fallback directly to the target directory
		if curl -fsSL "${REPO_BASE_URL}${REPO_LANDING_HTML}" -o "${_template_dst}"; then
			log_ok "Template downloaded successfully"
			_template_ok=1
		else
			# 3. Final fail content
			log_error "Failed to download template. Using basic fallback UI."
			echo "<html><body><h1>GNS3 Config Server</h1><p>Template missing. Check server terminal for config details.</p></body></html>" >"${_template_dst}"
		fi
	fi

	# Only run sed injections if we got the template (from either local or curl)
	if [[ "${_template_ok}" -eq 1 ]]; then
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
		sed -i "s|{{WITH_OPENVPN}}|${WITH_OPENVPN}|g" "${_template_dst}"
		sed -i "s|{{WITH_WIREGUARD}}|${WITH_WIREGUARD}|g" "${_template_dst}"
		sed -i "s|{{WITH_DOCKER}}|${WITH_DOCKER}|g" "${_template_dst}"
		sed -i "s|{{DISABLE_KVM}}|${DISABLE_KVM}|g" "${_template_dst}"
		sed -i "s|{{UNSAFE_CONFIGS}}|${UNSAFE_CONFIGS}|g" "${_template_dst}"
		sed -i "s|{{SERVE_SLUG}}|${_serve_slug}|g" "${_template_dst}"
		sed -i "s|{{SERVE_HOURS}}|${CONFIG_SERVE_HOURS}|g" "${_template_dst}"
		sed -i "s|{{SERVE_PORT}}|${CONFIG_SERVE_PORT}|g" "${_template_dst}"
		sed -i "s|{{WARNINGS_JSON}}|${_warnings_json}|g" "${_template_dst}"

		log_ok "Landing page generated"
	fi

	# ## Systemd units ##########################################################

	cat >/lib/systemd/system/gns3-config-serve.service <<EOF
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
EOF

	cat >/lib/systemd/system/gns3-config-serve-stop.timer <<EOF
[Unit]
Description=Stop GNS3 config server after ${CONFIG_SERVE_HOURS} hours

[Timer]
OnActiveSec=${CONFIG_SERVE_HOURS}h
AccuracySec=1min
Unit=gns3-config-serve-stop.service

[Install]
WantedBy=timers.target
EOF

	cat >/lib/systemd/system/gns3-config-serve-stop.service <<EOF
[Unit]
Description=Stop and clean up GNS3 config server

[Service]
Type=oneshot
ExecStart=/bin/systemctl stop gns3-config-serve.service
ExecStart=/bin/systemctl disable gns3-config-serve.service
ExecStart=/bin/rm -rf ${CONFIG_SERVE_DIR}
ExecStart=/bin/systemctl disable gns3-config-serve-stop.timer
EOF

	enable_and_start gns3-config-serve.service

	log_ok "Config server live on port ${CONFIG_SERVE_PORT} (auto-stops in ${CONFIG_SERVE_HOURS}h)"

	# MOTD
	cat >/etc/update-motd.d/70-gns3-vpn <<EOFMOTD
#!/bin/sh
if systemctl is-active --quiet gns3-config-serve.service 2>/dev/null; then
  echo ""
  echo "  GNS3 config: http://${_lan_ip}:${CONFIG_SERVE_PORT}/"
  echo "  (auto-expires — download configs now)"
fi
EOFMOTD
	chmod 755 /etc/update-motd.d/70-gns3-vpn
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

	if [[ -n "${_remote_ssh_ip}" ]]; then
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
		1194 | 51820)
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
		if [[ -n "${_remote_ssh_ip}" ]]; then
			ufw allow from "${_remote_ssh_ip}" to any port "${_port}" proto tcp \
				comment "GNS3 - ${_status}" >/dev/null 2>&1
		fi

		for _subnet in "${_local_subnets[@]}"; do
			ufw allow from "${_subnet}" to any port "${_port}" proto tcp \
				comment "GNS3 - ${_status}" >/dev/null 2>&1
		done
	done

	# Enable forwarding in ufw if any VPN is configured
	if [[ "${WITH_OPENVPN}" -eq 1 || "${WITH_WIREGUARD}" -eq 1 ]]; then
		local _ufw_default="/etc/default/ufw"
		if [[ -f "${_ufw_default}" ]]; then
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
	if [[ -n "${_invoker}" ]]; then
		log_info "Adding $_invoker to groups: ${REQUIRED_GROUPS[*]}"
		for _grp in "${REQUIRED_GROUPS[@]}"; do
			usermod -aG "${_grp}" "${_invoker}"
		done
		log_ok "Group membership updated for ${_invoker} (log out/in to take effect)"
	fi
}

add_gns3_repository() {
	log_info "Adding GNS3 PPA: ppa:gns3/${REPOSITORY}"
	apt-add-repository -y "ppa:gns3/${REPOSITORY}" >/dev/null
	log_ok "GNS3 repository added"
}

add_docker_repository() {
	if [[ -f "${DOCKER_KEYRING}" ]]; then
		log_info "Docker GPG key already present — skipping download"
	else
		log_info "Adding Docker CE repository..."
		install -m 0755 -d /etc/apt/keyrings
		curl -fsSL "${DOCKER_BASE_URL}/gpg" -o "${DOCKER_KEYRING}"
		chmod a+r "${DOCKER_KEYRING}"
	fi

	cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] ${DOCKER_BASE_URL} ${OS_CODENAME} stable
EOF
	log_ok "Docker repository configured"
}

install_packages() {
	log_info "Updating package index..."
	apt_retry update -qq

	if [[ "${NO_SYSTEM_UPGRADE}" -eq 0 ]]; then
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

### GNS3 server configuration #####################################

configure_gns3() {
	log_info "Writing GNS3 server configuration..."

	local _listen_host="0.0.0.0"
	if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
		_listen_host="172.16.253.1"
	fi

	local _hw_accel="True"
	if [[ "${DISABLE_KVM}" -eq 1 ]]; then
		_hw_accel="False"
		log_warn "KVM disabled — Qemu performance will be degraded"
	fi

	mkdir -p "${GNS3_CONF_DIR}"
	cat >"${GNS3_CONF_DIR}/gns3_server.conf" <<EOF
${DEPLOY_MARKER}
[Server]
host = ${_listen_host}
port = 3080
images_path = ${GNS3_HOME}/images
projects_path = ${GNS3_HOME}/projects
appliances_path = ${GNS3_HOME}/appliances
configs_path = ${GNS3_HOME}/configs
report_errors = True

[Qemu]
enable_hardware_acceleration = ${_hw_accel}
require_hardware_acceleration = ${_hw_accel}
EOF

	chown -R "${GNS3_USER}:${GNS3_USER}" "${GNS3_CONF_DIR}"
	chmod -R 700 "${GNS3_CONF_DIR}"
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

	cat >"${GNS3_SERVICE_FILE}" <<EOF
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
EOF

	chmod 644 "${GNS3_SERVICE_FILE}"
	chown root:root "${GNS3_SERVICE_FILE}"
	enable_and_start gns3
	log_ok "GNS3 service installed and enabled"
}

### OpenVPN setup ################################################

configure_openvpn() {
	log_info "Configuring OpenVPN..."

	local _my_ip
	_my_ip=$(get_public_ip)
	if [[ "${_my_ip}" == "UNKNOWN" ]]; then
		log_fatal "Could not determine public IP for OpenVPN configuration."
	fi
	log_info "Public IP detected: ${_my_ip}"

	local _hostname
	_hostname=$(hostname)

	[[ -d /dev/net ]] || mkdir -p /dev/net
	[[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200

	log_info "Generating OpenVPN keys..."
	mkdir -p /etc/openvpn
	if [[ "${USE_LEGACY_RSA}" -eq 1 ]]; then
		log_info "Using legacy RSA crypto (DH params may take a minute)..."
		[[ -f /etc/openvpn/dh.pem ]] || openssl dhparam -out /etc/openvpn/dh.pem 2048
		[[ -f /etc/openvpn/key.pem ]] || openssl genrsa -out /etc/openvpn/key.pem 2048
	else
		log_info "Using elliptic curve crypto (P-384)..."
		[[ -f /etc/openvpn/key.pem ]] || openssl ecparam -name secp384r1 -genkey \
			-noout -out /etc/openvpn/key.pem
	fi
	chmod 600 /etc/openvpn/key.pem
	[[ -f /etc/openvpn/csr.pem ]] || openssl req -new -key /etc/openvpn/key.pem \
		-out /etc/openvpn/csr.pem -subj /CN=OpenVPN/
	[[ -f /etc/openvpn/cert.pem ]] || openssl x509 -req -in /etc/openvpn/csr.pem \
		-out /etc/openvpn/cert.pem -signkey /etc/openvpn/key.pem -days 3650

	local _dh_client_block=""
	local _dh_server_line="dh none"
	if [[ "${USE_LEGACY_RSA}" -eq 1 ]]; then
		_dh_client_block="<dh>
$(cat /etc/openvpn/dh.pem)
</dh>"
		_dh_server_line="dh dh.pem"
	fi

	cat >/root/client.ovpn <<EOFCLIENT
client
nobind
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
${_dh_client_block}
<connection>
remote ${_my_ip} 1194 udp
</connection>
EOFCLIENT

	cat >/etc/openvpn/udp1194.conf <<EOFUDP
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
port 1194
dev tun1194
status openvpn-status-1194.log
log-append /var/log/openvpn-udp1194.log
EOFUDP

	# Restart with retry for failures (rare)
	enable_and_start openvpn
	log_ok "OpenVPN configured"
}

### WireGuard setup #############################################─

configure_wireguard() {
	log_info "Configuring WireGuard..."

	local _my_ip
	_my_ip=$(get_public_ip)
	if [[ "${_my_ip}" == "UNKNOWN" ]]; then
		log_fatal "Could not determine public IP for WireGuard configuration."
	fi

	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard

	if [[ ! -f /etc/wireguard/server.key ]]; then
		(
			umask 077
			wg genkey | tee /etc/wireguard/server.key | wg pubkey >/etc/wireguard/server.pub
		)
	fi

	local _server_privkey _server_pubkey
	_server_privkey=$(cat /etc/wireguard/server.key)
	_server_pubkey=$(cat /etc/wireguard/server.pub)

	if [[ ! -f /etc/wireguard/client1.key ]]; then
		(
			umask 077
			wg genkey | tee /etc/wireguard/client1.key | wg pubkey >/etc/wireguard/client1.pub
		)
	fi

	local _client_privkey _client_pubkey
	_client_privkey=$(cat /etc/wireguard/client1.key)
	_client_pubkey=$(cat /etc/wireguard/client1.pub)

	cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 172.16.254.1/24
ListenPort = 51820
PrivateKey = ${_server_privkey}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# client1
PublicKey = ${_client_pubkey}
AllowedIPs = 172.16.254.2/32
EOF

	chmod 600 /etc/wireguard/wg0.conf

	cat >/etc/wireguard/client1.conf <<EOF
[Interface]
Address = 172.16.254.2/24
PrivateKey = ${_client_privkey}
DNS = 1.1.1.1

[Peer]
PublicKey = ${_server_pubkey}
Endpoint = ${_my_ip}:51820
AllowedIPs = 172.16.253.0/24, 172.16.254.0/24
PersistentKeepalive = 25
EOF

	# Enable and restart with retry for failures (rare)
	enable_and_start wg-quick@wg0
	log_ok "WireGuard configured"
}

### Welcome setup ##############################################################─

configure_welcome() {
	log_info "Setting up GNS3-VM welcome console..."

	cat >/etc/sudoers.d/gns3 <<EOF
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-key
gns3   ALL = (ALL) NOPASSWD: /usr/bin/apt-get
gns3   ALL = (ALL) NOPASSWD: /usr/sbin/reboot
EOF
	chmod 440 /etc/sudoers.d/gns3

	curl -fsSL https://raw.githubusercontent.com/GNS3/gns3-server/master/scripts/welcome.py \
		-o /usr/local/bin/welcome.py
	chmod 755 /usr/local/bin/welcome.py
	chown "${GNS3_USER}:${GNS3_USER}" /usr/local/bin/welcome.py

	mkdir -p /etc/systemd/system/getty@tty1.service.d
	cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a gns3 --noclear %I $TERM
EOF
	chmod 644 /etc/systemd/system/getty@tty1.service.d/override.conf

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

validate() {
	log_info "Running post-install validation..."
	local _lan_ip
	_lan_ip=$(get_lan_ip)

	sleep 3

	if curl -sf --max-time 5 "http://${_lan_ip}:3080/v2/version" &>/dev/null; then
		log_ok "GNS3 API responding on ${_lan_ip}:3080"
	elif curl -sf --max-time 5 "http://localhost:3080/v2/version" &>/dev/null; then
		log_ok "GNS3 API responding on localhost:3080"
	else
		log_warn_sticky "GNS3 API not responding on port 3080"
		log_warn_sticky "  Check: journalctl -u gns3 --no-pager -n 20"
	fi

	if [[ "${WITH_DOCKER}" -eq 1 ]]; then
		if docker info &>/dev/null; then
			log_ok "Docker engine responding"
		else
			log_warn_sticky "Docker installed but not responding"
		fi
	fi

	local _gns3_bin="/usr/bin/gns3server"
	[[ -x "${GNS3_VENV}/bin/gns3server" ]] && _gns3_bin="${GNS3_VENV}/bin/gns3server"
	if "${_gns3_bin}" --version &>/dev/null; then
		log_ok "gns3server binary: $(${_gns3_bin} --version 2>&1 | head -1)"
	else
		log_warn_sticky "gns3server binary cannot execute — possible Python venv issue"
		log_warn_sticky "  Binary: ${_gns3_bin}"
		log_warn_sticky "  Check:  ${_gns3_bin} --version"
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
	printf "${GREEN}${BOLD}"
	echo "  GNS3 Server Install Complete"
	printf "%s" "${NC}"
	echo "  ##################################"
	echo ""
	printf "  Server: http://%s:3080\n" "${_lan_ip}"
	printf "  Config: %s/gns3_server.conf\n" "${GNS3_CONF_DIR}"
	printf "  Data:   %s/\n" "${GNS3_HOME}"
	echo "  Logs:   /var/log/gns3/gns3.log"
	echo "  Status: systemctl status gns3"
	echo ""

	if [[ "${WITH_OPENVPN}" -eq 1 || "${WITH_WIREGUARD}" -eq 1 ]]; then
		echo "  VPN"
		echo "  ##################################"

		if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
			echo "  WireGuard: ${_public_ip}:51820"
			echo "    Tunnel:  172.16.254.1:3080"
		fi

		if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
			echo "  OpenVPN:   ${_public_ip}:1194/udp"
			echo "    Tunnel:  172.16.253.1:3080"
		fi
		echo ""
	fi

	# Config server info
	if [[ -f "${CONFIG_SERVE_DIR}/.serve_slug" ]]; then
		local _serve_slug
		_serve_slug=$(cat "${CONFIG_SERVE_DIR}/.serve_slug")
		echo "  Landing page:"
		echo "  http://${_lan_ip}:${CONFIG_SERVE_PORT}/"
		printf "  ${YELLOW}Expires in ${CONFIG_SERVE_HOURS}h${NC}\n"
		echo ""
	fi

	# Encrypted config download commands
	if [[ -f "${CONFIG_SERVE_DIR}/.passphrase" ]]; then
		local _pass _serve_slug
		_pass=$(cat "${CONFIG_SERVE_DIR}/.passphrase")
		_serve_slug=$(cat "${CONFIG_SERVE_DIR}/.serve_slug")

		echo "  Secure config download"
		echo "  ##################################"

		if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then
			printf "  ${CYAN}WireGuard:${NC}\n"
			echo "  curl -s http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/wg-client1.conf.enc \\"
			echo "    | openssl enc -d -aes-256-cbc -pbkdf2 -iter 15000 -salt \\"
			echo "    -pass pass:${_pass} -a > wg-client1.conf"
			echo ""
		fi

		if [[ "${WITH_OPENVPN}" -eq 1 ]]; then
			printf "  ${CYAN}OpenVPN:${NC}\n"
			echo "  curl -s http://${_lan_ip}:${CONFIG_SERVE_PORT}/${_serve_slug}/$(hostname).ovpn.enc \\"
			echo "    | openssl enc -d -aes-256-cbc -pbkdf2 -iter 15000 -salt \\"
			echo "    -pass pass:${_pass} -a > $(hostname).ovpn"
			echo ""
		fi
	fi

	if [[ "${DISABLE_KVM}" -eq 1 ]]; then
		printf "  ${YELLOW}KVM: DISABLED${NC}\n"
		echo ""
	fi

	local _invoker
	_invoker=$(detect_invoking_user)
	if [[ -n "${_invoker}" ]]; then
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
	trap 'log_error "Failed at line $LINENO."' ERR

	preflight_checks

	readonly OS_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

	# # Phase 1: Repositories ##################################################

	add_gns3_repository
	if [[ "${WITH_DOCKER}" -eq 1 ]]; then add_docker_repository; fi

	# # Phase 2: Packages (single apt pass) ####################################

	install_packages

	# # Phase 3: Users and groups ##############################################

	setup_groups
	setup_gns3_user
	propagate_groups_to_invoker

	# # Phase 4: Configuration ################################################─

	configure_gns3
	install_gns3_service

	if [[ "${WITH_OPENVPN}" -eq 1 ]]; then configure_openvpn; fi
	if [[ "${WITH_WIREGUARD}" -eq 1 ]]; then configure_wireguard; fi
	if [[ "${WITH_WELCOME}" -eq 1 ]]; then configure_welcome; fi

	if [[ "${WITH_OPENVPN}" -eq 1 || "${WITH_WIREGUARD}" -eq 1 ]]; then
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
