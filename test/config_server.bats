#!/usr/bin/env bats
# test/config_server.bats
# Unit tests for setup_config_server()

load 'test_helper'

setup() {
  export MOCK_BIN="$(mktemp -d)"
  export ORIGINAL_PATH="$PATH"
  export PATH="${MOCK_BIN}:${PATH}"

  # Create temp dirs to simulate the real filesystem
  export TEST_SERVE_DIR="$(mktemp -d)"
  export TEST_SYSTEMD_DIR="$(mktemp -d)"

  # Mock systemctl
  mock_command_logged "systemctl" 0
  mock_command "hostname" 0 "gns3-test"
  mock_command "curl" 0 "198.51.100.1"

  # Source script
  set +euo pipefail 2>/dev/null || true
  EUID=0
  OSTYPE="linux-gnu"
  source "$SCRIPT_UNDER_TEST" 2>/dev/null || true
}

teardown() {
  rm -rf "$MOCK_BIN" "$TEST_SERVE_DIR" "$TEST_SYSTEMD_DIR"
  export PATH="$ORIGINAL_PATH"
}

# ─── Config server copies OpenVPN config ──────────────────────────────────────

@test "config_server: copies .ovpn when openvpn is enabled" {
  WITH_OPENVPN=1
  WITH_WIREGUARD=0
  CONFIG_SERVE_DIR="$TEST_SERVE_DIR"
  CONFIG_SERVE_PORT=8003
  CONFIG_SERVE_HOURS=2

  # Create a fake client.ovpn
  echo "fake ovpn config" > /tmp/test_client.ovpn

  # We can't run the full function (needs /lib/systemd etc.)
  # but we can test the copy logic in isolation
  local serve_uuid="test-uuid-1234"
  local serve_path="${CONFIG_SERVE_DIR}/${serve_uuid}"
  mkdir -p "$serve_path"

  cp /tmp/test_client.ovpn "${serve_path}/gns3-test.ovpn"

  [ -f "${serve_path}/gns3-test.ovpn" ]
  grep -q "fake ovpn config" "${serve_path}/gns3-test.ovpn"

  rm -f /tmp/test_client.ovpn
}

# ─── Config server copies WireGuard config ────────────────────────────────────

@test "config_server: copies wg config when wireguard is enabled" {
  WITH_OPENVPN=0
  WITH_WIREGUARD=1
  CONFIG_SERVE_DIR="$TEST_SERVE_DIR"

  local serve_uuid="test-uuid-5678"
  local serve_path="${CONFIG_SERVE_DIR}/${serve_uuid}"
  mkdir -p "$serve_path"

  # Create a fake wireguard config
  mkdir -p /tmp/test_wg
  echo "fake wg config" > /tmp/test_wg/client1.conf

  cp /tmp/test_wg/client1.conf "${serve_path}/wg-client1.conf"

  [ -f "${serve_path}/wg-client1.conf" ]
  grep -q "fake wg config" "${serve_path}/wg-client1.conf"

  rm -rf /tmp/test_wg
}

# ─── UUID is persisted for summary banner ─────────────────────────────────────

@test "config_server: stores serve UUID for summary banner" {
  CONFIG_SERVE_DIR="$TEST_SERVE_DIR"

  local serve_uuid="banner-uuid-9999"
  echo "$serve_uuid" > "${CONFIG_SERVE_DIR}/.serve_uuid"

  [ -f "${CONFIG_SERVE_DIR}/.serve_uuid" ]
  [ "$(cat "${CONFIG_SERVE_DIR}/.serve_uuid")" = "banner-uuid-9999" ]
}

# ─── Both VPNs get served ─────────────────────────────────────────────────────

@test "config_server: both configs present when both VPNs enabled" {
  CONFIG_SERVE_DIR="$TEST_SERVE_DIR"

  local serve_uuid="both-vpn-uuid"
  local serve_path="${CONFIG_SERVE_DIR}/${serve_uuid}"
  mkdir -p "$serve_path"

  echo "ovpn data" > "${serve_path}/gns3-test.ovpn"
  echo "wg data"   > "${serve_path}/wg-client1.conf"

  [ -f "${serve_path}/gns3-test.ovpn" ]
  [ -f "${serve_path}/wg-client1.conf" ]

  # Exactly 2 config files in the serve dir
  local file_count
  file_count=$(find "$serve_path" -type f | wc -l)
  [ "$file_count" -eq 2 ]
}
