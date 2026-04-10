#!/usr/bin/env bats
# test/firewall.bats
# Unit tests for configure_firewall()

load 'test_helper'

# ─── No ufw installed ────────────────────────────────────────────────────────

@test "firewall: warns with port list when ufw not found" {
  # Remove any ufw mock so command -v fails
  rm -f "${MOCK_BIN}/ufw"
  DISABLE_FIREWALL=0
  REQUIRED_PORTS=(3080 1194 51820)

  run configure_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"No ufw detected"* ]]
  [[ "$output" == *"3080"* ]]
  [[ "$output" == *"1194"* ]]
}

# ─── ufw installed but inactive ──────────────────────────────────────────────

@test "firewall: warns when ufw is installed but inactive" {
  mock_command "ufw" 0 "Status: inactive"
  DISABLE_FIREWALL=0
  REQUIRED_PORTS=(3080)

  run configure_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* ]]
}

# ─── --without-firewall flag ─────────────────────────────────────────────────

@test "firewall: skips everything with --without-firewall" {
  mock_command_logged "ufw" 0 "Status: active"
  DISABLE_FIREWALL=1

  run configure_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping firewall"* ]]
  # ufw should never have been called for allow rules
  [ ! -f "${MOCK_BIN}/ufw.calls" ]
}

# ─── ufw active — rules applied ──────────────────────────────────────────────

@test "firewall: opens required ports when ufw is active" {
  # ufw needs to return "active" for the status check but also
  # succeed for the allow calls.  We use a stateful mock.
  cat > "${MOCK_BIN}/ufw" <<'MOCK'
#!/bin/bash
if [[ "$1" == "status" ]]; then
  echo "Status: active"
elif [[ "$1" == "allow" ]]; then
  echo "$@" >> "${MOCK_BIN}/ufw.calls"
elif [[ "$1" == "reload" ]]; then
  echo "reloaded" >> "${MOCK_BIN}/ufw.calls"
fi
exit 0
MOCK
  chmod +x "${MOCK_BIN}/ufw"

  DISABLE_FIREWALL=0
  WITH_OPENVPN=1
  WITH_WIREGUARD=1
  REQUIRED_PORTS=(3080 1194 8003 51820)

  run configure_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"ufw rules applied"* ]]

  # Verify port rules were created
  grep -q "3080/tcp" "${MOCK_BIN}/ufw.calls"
  grep -q "1194/tcp" "${MOCK_BIN}/ufw.calls"
  grep -q "1194/udp" "${MOCK_BIN}/ufw.calls"
  grep -q "51820/udp" "${MOCK_BIN}/ufw.calls"
}
