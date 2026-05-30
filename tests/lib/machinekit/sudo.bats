#!/usr/bin/env bats
# Tests for lib/machinekit/sudo.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  unset _MK_SUDO_LOADED
  # shellcheck source=../../../lib/machinekit/sudo.sh
  source "$MACHINEKIT_DIR/lib/machinekit/sudo.sh"
  unset MK_SUDO_KEEPALIVE_PID

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::warn
  mktest::stub_function logging::error
  mktest::stub_function logging::info
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  sudo::ensure() { echo "original"; }
  _MK_SUDO_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/sudo.sh"
  [ "$(sudo::ensure)" = "original" ]
}

# --- sudo::ensure ---

@test "ensure starts keepalive and returns when sudo credentials are cached" {
  mktest::stub_function sudo "-n" "true"
  mktest::stub_function sudo::keepalive_start
  sudo::ensure
  mktest::assert_stub_called sudo::keepalive_start
}

@test "ensure in dry-run warns but does not fail when sudo is not cached" {
  STUB_RETURN=1 mktest::stub_function sudo "-n" "true"
  mktest::stub_function input::is_dry_run
  mktest::stub_function sudo::keepalive_start
  sudo::ensure
  mktest::assert_stub_not_called sudo::keepalive_start
}

@test "ensure in interactive mode prompts and starts keepalive when sudo is not cached" {
  STUB_RETURN=1 mktest::stub_function sudo "-n" "true"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::is_interactive
  mktest::stub_function sudo "-v"
  mktest::stub_function sudo::keepalive_start
  sudo::ensure
  mktest::assert_stub_called sudo "-v"
  mktest::assert_stub_called sudo::keepalive_start
}

@test "ensure in non-interactive mode fails with instructions when sudo is not cached" {
  STUB_RETURN=1 mktest::stub_function sudo "-n" "true"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  run ! sudo::ensure
  MATCH="non-interactive" mktest::assert_stub_called logging::error
}

# --- sudo::keepalive_start ---

@test "keepalive_start spawns a background process and registers cleanup" {
  # Stub sudo so the background loop doesn't touch the real binary. Return
  # failure so the loop exits immediately via `|| exit` rather than sleeping.
  STUB_RETURN=1 mktest::stub_function sudo
  mktest::stub_function lifecycle::register_cleanup "sudo::keepalive_stop"
  sudo::keepalive_start
  [ -n "${MK_SUDO_KEEPALIVE_PID:-}" ]
  mktest::assert_stub_called lifecycle::register_cleanup "sudo::keepalive_stop"
}

@test "keepalive_start is idempotent when already running" {
  mktest::stub_function sudo
  mktest::stub_function lifecycle::register_cleanup "sudo::keepalive_stop"
  export MK_SUDO_KEEPALIVE_PID=99999
  sudo::keepalive_start
  mktest::assert_stub_not_called lifecycle::register_cleanup "sudo::keepalive_stop"
}

# --- sudo::keepalive_stop ---

@test "keepalive_stop kills the keepalive process and clears the PID" {
  ( while true; do sleep 10; done ) &
  MK_SUDO_KEEPALIVE_PID=$!
  sudo::keepalive_stop
  [ -z "${MK_SUDO_KEEPALIVE_PID:-}" ]
}

@test "keepalive_stop is a no-op when no keepalive is running" {
  unset MK_SUDO_KEEPALIVE_PID
  sudo::keepalive_stop
}
