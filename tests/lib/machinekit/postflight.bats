#!/usr/bin/env bats
# Tests for lib/machinekit/postflight.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/postflight.sh
  source "$MACHINEKIT_DIR/lib/machinekit/postflight.sh"

  # Logging and output collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::success
  mktest::stub_function logging::info
  mktest::stub_function logging::dry_run
}

# --- double-source guard ---

@test "sourcing a second time is a no-op" {
  # Re-sourcing with the guard already set must not redefine functions or error.
  _MK_POSTFLIGHT_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/postflight.sh"
}

# --- postflight::run ---

@test "run in dry-run mode calls logging::dry_run with a dry-run message and skips the exec hint" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postflight::_print_exec_hint
  postflight::run
  MATCH="dry.run" mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called postflight::_print_exec_hint
}

@test "run in real mode logs success and prints the exec hint" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postflight::_print_exec_hint
  postflight::run
  MATCH="apply complete" mktest::assert_stub_called logging::success
  mktest::assert_stub_called postflight::_print_exec_hint
}

# --- postflight::_print_exec_hint ---

@test "_print_exec_hint logs the exec command" {
  postflight::_print_exec_hint
  MATCH="exec" mktest::assert_stub_called logging::info
}
