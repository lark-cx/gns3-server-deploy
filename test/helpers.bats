#!/usr/bin/env bats
# test/helpers.bats
# Unit tests for utility/helper functions.

load 'test_helper'

# ─── detect_invoking_user ─────────────────────────────────────────────────────

@test "detect_invoking_user: returns SUDO_USER when set and non-root" {
  SUDO_USER="shane"
  run detect_invoking_user
  [ "$status" -eq 0 ]
  [ "$output" = "shane" ]
}

@test "detect_invoking_user: returns nothing when SUDO_USER is root" {
  SUDO_USER="root"
  run detect_invoking_user
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_invoking_user: returns nothing when SUDO_USER is unset" {
  unset SUDO_USER
  run detect_invoking_user
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ─── get_public_ip ────────────────────────────────────────────────────────────

@test "get_public_ip: returns UNKNOWN when all curl calls fail" {
  mock_command "curl" 1
  run get_public_ip
  [ "$output" = "UNKNOWN" ]
}

@test "get_public_ip: returns IP from first successful source" {
  mock_command "curl" 0 "203.0.113.42"
  run get_public_ip
  [ "$output" = "203.0.113.42" ]
}

# ─── apt_retry ────────────────────────────────────────────────────────────────

@test "apt_retry: succeeds on first attempt when apt works" {
  mock_command_logged "apt-get" 0
  run apt_retry install -y vim
  [ "$status" -eq 0 ]
  # Verify apt-get was called with our args
  [ -f "${MOCK_BIN}/apt-get.calls" ]
  grep -q "install -y vim" "${MOCK_BIN}/apt-get.calls"
}

@test "apt_retry: retries on failure and eventually fatals" {
  mock_command_logged "apt-get" 1
  # Override sleep so we don't wait 15s in tests
  sleep() { :; }
  export -f sleep

  run apt_retry install -y nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed after 3 attempts"* ]]

  # Should have been called 3 times
  local call_count
  call_count=$(wc -l < "${MOCK_BIN}/apt-get.calls")
  [ "$call_count" -eq 3 ]
}

# ─── ensure_group ─────────────────────────────────────────────────────────────

@test "ensure_group: calls groupadd when group doesn't exist" {
  # Mock getent to fail (group doesn't exist)
  mock_command "getent" 2
  mock_command_logged "groupadd" 0

  run ensure_group "testgroup"
  [ "$status" -eq 0 ]
  grep -q "\-\-system testgroup" "${MOCK_BIN}/groupadd.calls"
}

@test "ensure_group: skips groupadd when group already exists" {
  # Mock getent to succeed (group exists)
  mock_command "getent" 0
  mock_command_logged "groupadd" 0

  run ensure_group "existinggroup"
  [ "$status" -eq 0 ]
  # groupadd should NOT have been called
  [ ! -f "${MOCK_BIN}/groupadd.calls" ]
}

# ─── Logging functions ───────────────────────────────────────────────────────

@test "log_info: writes to stderr" {
  run log_info "test message"
  [[ "$output" == *"[INFO]"* ]]
  [[ "$output" == *"test message"* ]]
}

@test "log_error: writes to stderr" {
  run log_error "something broke"
  [[ "$output" == *"[FAIL]"* ]]
  [[ "$output" == *"something broke"* ]]
}

@test "log_ok: writes to stderr" {
  run log_ok "it worked"
  [[ "$output" == *"[ OK ]"* ]]
  [[ "$output" == *"it worked"* ]]
}
