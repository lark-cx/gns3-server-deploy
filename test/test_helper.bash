#!/usr/bin/env bash
# test/test_helper.bash
# Shared setup for all BATS test files.
# Sources the installer so functions are available, without running main.

# Path to the script under test
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_UNDER_TEST="${SCRIPT_DIR}/gns3-remote-install-redux.sh"

# Load bats helpers if installed
load '/usr/lib/bats-support/load.bash'  2>/dev/null || true
load '/usr/lib/bats-assert/load.bash'   2>/dev/null || true

# ── Mock infrastructure ──────────────────────────────────────────────────────

# Create a temp bin directory for mock commands.
# Any function can drop an executable into MOCK_BIN to shadow a real command.
setup() {
  export MOCK_BIN="$(mktemp -d)"
  export ORIGINAL_PATH="$PATH"
  export PATH="${MOCK_BIN}:${PATH}"

  # Source the script. Because we've wrapped main in an
  # `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then` guard,
  # sourcing just loads functions + variables without executing.
  #
  # We also need to fake enough environment that the top-level
  # variable assignments don't blow up under `set -u`.
  export EUID=0
  export OSTYPE="linux-gnu"

  # Suppress strict mode for sourcing (callers re-enable as needed)
  set +euo pipefail 2>/dev/null || true
  source "$SCRIPT_UNDER_TEST" 2>/dev/null || true
}

teardown() {
  rm -rf "$MOCK_BIN"
  export PATH="$ORIGINAL_PATH"
}

# ── Helper: create a mock command ─────────────────────────────────────────────
# Usage: mock_command <name> [exit_code] [stdout_text]
mock_command() {
  local name="$1"
  local exit_code="${2:-0}"
  local stdout="${3:-}"
  cat > "${MOCK_BIN}/${name}" <<EOF
#!/bin/bash
echo "$stdout"
exit $exit_code
EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# ── Helper: create a mock that logs its invocations ──────────────────────────
# Usage: mock_command_logged <name> [exit_code]
# Check calls with: cat "${MOCK_BIN}/<name>.calls"
mock_command_logged() {
  local name="$1"
  local exit_code="${2:-0}"
  cat > "${MOCK_BIN}/${name}" <<EOF
#!/bin/bash
echo "\$@" >> "${MOCK_BIN}/${name}.calls"
exit $exit_code
EOF
  chmod +x "${MOCK_BIN}/${name}"
}
