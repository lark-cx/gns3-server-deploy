#!/usr/bin/env bats
# test/integration.bats
# Integration tests — run these inside a real Ubuntu VM, NOT in a container.
#
# Prerequisites:
#   - Fresh Ubuntu 24.04 VM (snapshot before running)
#   - Run as root: sudo bats test/integration.bats
#   - Internet access for apt/PPA
#
# These tests modify system state. Restore from snapshot after each run.

SCRIPT="./gns3-remote-install-redux.sh"

# ─── Smoke test: --help doesn't blow up ───────────────────────────────────────

@test "integration: --help exits 0 and shows usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-openvpn"* ]]
  [[ "$output" == *"--with-wireguard"* ]]
  [[ "$output" == *"--without-firewall"* ]]
}

# ─── Invalid flag produces error ──────────────────────────────────────────────

@test "integration: unknown flag exits nonzero" {
  run bash "$SCRIPT" --with-ponies
  [ "$status" -ne 0 ]
}

# ─── Minimal install (no VPN, no Docker, skip upgrade) ────────────────────────
# This is the fastest path — good for verifying core mechanics.

@test "integration: minimal install creates gns3 user and service" {
  run bash "$SCRIPT" --without-docker --without-kvm --without-system-upgrade --without-firewall
  [ "$status" -eq 0 ]

  # GNS3 user exists
  id gns3

  # Home directory structure
  [ -d /opt/gns3/images ]
  [ -d /opt/gns3/projects ]
  [ -d /opt/gns3/appliances ]
  [ -d /opt/gns3/configs ]

  # Config file
  [ -f /etc/gns3/gns3_server.conf ]
  grep -q "hardware_acceleration = False" /etc/gns3/gns3_server.conf

  # Systemd service installed
  [ -f /lib/systemd/system/gns3.service ]
  systemctl is-enabled gns3
}

# ─── WireGuard install ────────────────────────────────────────────────────────

@test "integration: --with-wireguard creates keys and config" {
  run bash "$SCRIPT" --with-wireguard --without-docker --without-kvm --without-system-upgrade --without-firewall
  [ "$status" -eq 0 ]

  # Keys generated
  [ -f /etc/wireguard/server.key ]
  [ -f /etc/wireguard/server.pub ]
  [ -f /etc/wireguard/client1.key ]
  [ -f /etc/wireguard/client1.pub ]

  # Configs written
  [ -f /etc/wireguard/wg0.conf ]
  [ -f /etc/wireguard/client1.conf ]

  # Permissions locked down
  local key_perms
  key_perms=$(stat -c '%a' /etc/wireguard/server.key)
  [ "$key_perms" = "600" ]

  # IP forwarding enabled
  [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]

  # Config server running
  systemctl is-active gns3-config-serve.service
  # Timer set
  systemctl is-active gns3-config-serve-stop.timer
}

# ─── Docker install ───────────────────────────────────────────────────────────

@test "integration: docker group and service created" {
  run bash "$SCRIPT" --without-kvm --without-system-upgrade --without-firewall
  [ "$status" -eq 0 ]

  # Docker installed
  command -v docker
  systemctl is-active docker

  # gns3 user in docker group
  id -nG gns3 | grep -q docker
}

# ─── SUDO_USER group propagation ─────────────────────────────────────────────

@test "integration: invoking user gets added to required groups" {
  # Create a test user to simulate SUDO_USER
  useradd -m testinvoker 2>/dev/null || true
  export SUDO_USER="testinvoker"

  run bash "$SCRIPT" --without-docker --without-kvm --without-system-upgrade --without-firewall
  [ "$status" -eq 0 ]

  # testinvoker should be in kvm and ubridge groups
  id -nG testinvoker | grep -q kvm
  id -nG testinvoker | grep -q ubridge

  # Cleanup
  userdel -r testinvoker 2>/dev/null || true
}

# ─── Idempotency: running twice doesn't break ────────────────────────────────

@test "integration: second run completes without error" {
  bash "$SCRIPT" --without-docker --without-kvm --without-system-upgrade --without-firewall
  run bash "$SCRIPT" --without-docker --without-kvm --without-system-upgrade --without-firewall
  [ "$status" -eq 0 ]

  # User still exists, not duplicated
  local user_count
  user_count=$(grep -c "^gns3:" /etc/passwd)
  [ "$user_count" -eq 1 ]
}
