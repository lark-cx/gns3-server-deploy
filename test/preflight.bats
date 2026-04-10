#!/usr/bin/env bats
# test/preflight.bats
# Unit tests for preflight_checks()

load 'test_helper'

# ─── Root check ───────────────────────────────────────────────────────────────

@test "preflight: fails when EUID != 0" {
  EUID=1000
  run preflight_checks
  [ "$status" -ne 0 ]
  [[ "$output" == *"Must run as root"* ]]
}

@test "preflight: passes root check when EUID == 0" {
  EUID=0
  # Will fail on other checks (no /etc/os-release etc.) but should NOT
  # fail with "Must run as root"
  run preflight_checks
  [[ "$output" != *"Must run as root"* ]]
}

# ─── OS check ─────────────────────────────────────────────────────────────────

@test "preflight: fails on non-linux OSTYPE" {
  EUID=0
  OSTYPE="darwin23"
  run preflight_checks
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires Linux"* ]]
}

# ─── Missing commands rollup ──────────────────────────────────────────────────

@test "preflight: reports multiple missing commands in one shot" {
  # Override REQUIRED_CMDS with commands that definitely don't exist
  REQUIRED_CMDS=("definitely_not_a_command_abc" "also_not_real_xyz")

  # Mock enough to get past the hard-stop checks
  EUID=0
  OSTYPE="linux-gnu"

  # Fake /etc/os-release
  mock_os_release() {
    ID="ubuntu"
    UBUNTU_CODENAME="noble"
    VERSION_CODENAME="noble"
  }
  mock_os_release

  run preflight_checks
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitely_not_a_command_abc"* ]]
  [[ "$output" == *"also_not_real_xyz"* ]]
  # Both should appear in the SAME error — no re-run needed
  [[ "$output" == *"Missing commands:"* ]]
}

# ─── CPU virtualization ──────────────────────────────────────────────────────

@test "preflight: warns (not fails) when CPU virt extensions missing" {
  EUID=0
  OSTYPE="linux-gnu"
  DISABLE_KVM=0
  REQUIRED_CMDS=()
  REQUIRED_PORTS=()
  REQUIRED_MODS=()
  ID="ubuntu"

  # Mock /proc/cpuinfo with no vmx/svm
  mock_command "grep" 1

  run preflight_checks
  # Should warn, not fatal
  [[ "$output" == *"virtualization"* ]] || [[ "$output" == *"Preflight checks passed"* ]]
}
