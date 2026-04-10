#!/usr/bin/env bats
# test/rollup.bats
# Unit tests for the flag-based array rollup logic.
# These verify that toggling WITH_* flags correctly builds up the
# REQUIRED_PORTS, REQUIRED_PKGS, REQUIRED_MODS, and REQUIRED_GROUPS arrays.

load 'test_helper'

# ─── Baseline (no VPN, no Docker) ────────────────────────────────────────────

@test "rollup: baseline has port 3080 only" {
  WITH_OPENVPN=0
  WITH_WIREGUARD=0
  WITH_DOCKER=0
  REQUIRED_PORTS=(3080)
  REQUIRED_PKGS=()
  REQUIRED_MODS=(kvm)
  REQUIRED_GROUPS=(kvm ubridge)

  # No rollup happens — arrays stay as-is
  [[ " ${REQUIRED_PORTS[*]} " == *" 3080 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " != *" 1194 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " != *" 51820 "* ]]
}

# ─── OpenVPN rollup ──────────────────────────────────────────────────────────

@test "rollup: --with-openvpn adds port 1194 and openvpn packages" {
  WITH_OPENVPN=1
  WITH_WIREGUARD=0
  REQUIRED_PORTS=(3080)
  REQUIRED_PKGS=()
  CONFIG_SERVE_PORT=8003

  # Simulate the rollup block
  if [[ "$WITH_OPENVPN" -eq 1 ]]; then
    REQUIRED_PORTS+=(1194)
    REQUIRED_PKGS+=("${PKGS_OPENVPN[@]}")
  fi
  if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
    REQUIRED_PORTS+=("$CONFIG_SERVE_PORT")
  fi

  [[ " ${REQUIRED_PORTS[*]} " == *" 1194 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " == *" 8003 "* ]]
  [[ " ${REQUIRED_PKGS[*]} " == *"openvpn"* ]]
  [[ " ${REQUIRED_PKGS[*]} " == *"dnsutils"* ]]
  # nginx-light should NOT be present (replaced by python http.server)
  [[ " ${REQUIRED_PKGS[*]} " != *"nginx-light"* ]]
}

# ─── WireGuard rollup ────────────────────────────────────────────────────────

@test "rollup: --with-wireguard adds port 51820 and wireguard module" {
  WITH_OPENVPN=0
  WITH_WIREGUARD=1
  REQUIRED_PORTS=(3080)
  REQUIRED_MODS=(kvm)
  REQUIRED_PKGS=()
  CONFIG_SERVE_PORT=8003

  if [[ "$WITH_WIREGUARD" -eq 1 ]]; then
    REQUIRED_PORTS+=(51820)
    REQUIRED_MODS+=(wireguard)
    REQUIRED_PKGS+=("${PKGS_WIREGUARD[@]}")
  fi
  if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
    REQUIRED_PORTS+=("$CONFIG_SERVE_PORT")
  fi

  [[ " ${REQUIRED_PORTS[*]} " == *" 51820 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " == *" 8003 "* ]]
  [[ " ${REQUIRED_MODS[*]} " == *"wireguard"* ]]
  [[ " ${REQUIRED_PKGS[*]} " == *"wireguard-tools"* ]]
}

# ─── Docker rollup ───────────────────────────────────────────────────────────

@test "rollup: docker adds docker group and all 5 packages as separate elements" {
  WITH_DOCKER=1
  REQUIRED_PKGS=()
  REQUIRED_GROUPS=(kvm ubridge)

  if [[ "$WITH_DOCKER" -eq 1 ]]; then
    REQUIRED_PKGS+=("${PKGS_DOCKER[@]}")
    REQUIRED_GROUPS+=(docker)
  fi

  # Verify each Docker package is its own array element (not space-joined)
  [[ " ${REQUIRED_PKGS[*]} " == *"docker-ce"* ]]
  [[ " ${REQUIRED_PKGS[*]} " == *"containerd.io"* ]]
  [[ " ${REQUIRED_PKGS[*]} " == *"docker-compose-plugin"* ]]
  [[ " ${REQUIRED_GROUPS[*]} " == *"docker"* ]]

  # Critical: each package should be a separate element
  # If they got flattened into one string, element count would be wrong
  [ "${#REQUIRED_PKGS[@]}" -eq 5 ]
}

# ─── Both VPNs ────────────────────────────────────────────────────────────────

@test "rollup: both VPNs together adds all ports, config serve port once" {
  WITH_OPENVPN=1
  WITH_WIREGUARD=1
  REQUIRED_PORTS=(3080)
  REQUIRED_MODS=(kvm)
  REQUIRED_PKGS=()
  CONFIG_SERVE_PORT=8003

  if [[ "$WITH_OPENVPN" -eq 1 ]]; then
    REQUIRED_PORTS+=(1194)
    REQUIRED_PKGS+=("${PKGS_OPENVPN[@]}")
  fi
  if [[ "$WITH_WIREGUARD" -eq 1 ]]; then
    REQUIRED_PORTS+=(51820)
    REQUIRED_MODS+=(wireguard)
    REQUIRED_PKGS+=("${PKGS_WIREGUARD[@]}")
  fi
  if [[ "$WITH_OPENVPN" -eq 1 || "$WITH_WIREGUARD" -eq 1 ]]; then
    REQUIRED_PORTS+=("$CONFIG_SERVE_PORT")
  fi

  [[ " ${REQUIRED_PORTS[*]} " == *" 3080 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " == *" 1194 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " == *" 51820 "* ]]
  [[ " ${REQUIRED_PORTS[*]} " == *" 8003 "* ]]

  # 8003 should appear exactly once
  local count=0
  for p in "${REQUIRED_PORTS[@]}"; do
    [[ "$p" == "8003" ]] && ((count++))
  done
  [ "$count" -eq 1 ]
}
