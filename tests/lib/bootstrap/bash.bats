#!/usr/bin/env bats
# Tests for lib/bootstrap/bash.sh — resolves a bash that meets the 5.3 floor,
# installing brew's bash when the running one is too old. Pure-3.2.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # Isolate from any MACHINEKIT_BASH override in the ambient shell; tests that
  # exercise the override set it explicitly.
  unset MACHINEKIT_BASH
  # shellcheck source=../../../lib/bootstrap/bash.sh
  source "$MACHINEKIT_DIR/lib/bootstrap/bash.sh"
}

# --- bootstrap::bash::_version_of ---

@test "_version_of reports the major and minor of the given bash" {
  run bootstrap::bash::_version_of "$BASH"
  [ "$status" -eq 0 ]
  [ "$output" = "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}" ]
}

# --- bootstrap::bash::_current_meets_floor ---

@test "_current_meets_floor agrees with bash_floor::meets on the running version" {
  if bash_floor::meets "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"; then
    bootstrap::bash::_current_meets_floor
  else
    run ! bootstrap::bash::_current_meets_floor
  fi
}

# --- bootstrap::bash::_binary_meets_floor ---

@test "_binary_meets_floor is true when the binary reports at or above the floor" {
  STUB_OUTPUT="5 3" mktest::stub_function bootstrap::bash::_version_of "/fake/bash"
  bootstrap::bash::_binary_meets_floor /fake/bash
}

@test "_binary_meets_floor is false when the binary reports below the floor" {
  STUB_OUTPUT="5 1" mktest::stub_function bootstrap::bash::_version_of "/fake/bash"
  run ! bootstrap::bash::_binary_meets_floor /fake/bash
}

# --- bootstrap::bash::ensure_modern_bash ---

@test "ensure_modern_bash honors MACHINEKIT_BASH when it meets the floor, without installing" {
  mktest::stub_function bootstrap::bash::_binary_meets_floor "/override/bash"
  mktest::stub_function bootstrap::brew::ensure
  mktest::stub_function bootstrap::brew::install_bash
  MACHINEKIT_BASH=/override/bash run bootstrap::bash::ensure_modern_bash
  [ "$status" -eq 0 ]
  [ "$output" = "/override/bash" ]
  mktest::assert_stub_not_called bootstrap::brew::ensure
  mktest::assert_stub_not_called bootstrap::brew::install_bash
}

@test "ensure_modern_bash fails when MACHINEKIT_BASH is below the floor, without installing" {
  STUB_RETURN=1 mktest::stub_function bootstrap::bash::_binary_meets_floor "/override/bash"
  STUB_EXIT=1 mktest::stub_function bootstrap::brew::_fail
  mktest::stub_function bootstrap::brew::install_bash
  MACHINEKIT_BASH=/override/bash run bootstrap::bash::ensure_modern_bash
  [ "$status" -ne 0 ]
  mktest::assert_stub_called bootstrap::brew::_fail
  mktest::assert_stub_not_called bootstrap::brew::install_bash
}

@test "ensure_modern_bash returns the running bash when it already meets the floor" {
  mktest::stub_function bootstrap::bash::_current_meets_floor
  mktest::stub_function bootstrap::brew::ensure
  run bootstrap::bash::ensure_modern_bash
  [ "$status" -eq 0 ]
  [ "$output" = "$BASH" ]
  mktest::assert_stub_not_called bootstrap::brew::ensure
}

@test "ensure_modern_bash installs brew bash when the running one is too old, and returns it" {
  STUB_RETURN=1 mktest::stub_function bootstrap::bash::_current_meets_floor
  mktest::stub_function bootstrap::brew::ensure
  mktest::stub_function bootstrap::brew::install_bash
  STUB_OUTPUT="/opt/test-brew/bin/bash" mktest::stub_function bootstrap::brew::bash_path
  mktest::stub_function bootstrap::bash::_binary_meets_floor "/opt/test-brew/bin/bash"
  run bootstrap::bash::ensure_modern_bash
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/test-brew/bin/bash" ]
  mktest::assert_stub_called bootstrap::brew::ensure
  mktest::assert_stub_called bootstrap::brew::install_bash
}

@test "ensure_modern_bash fails when even the installed bash is below the floor" {
  STUB_RETURN=1 mktest::stub_function bootstrap::bash::_current_meets_floor
  mktest::stub_function bootstrap::brew::ensure
  mktest::stub_function bootstrap::brew::install_bash
  STUB_OUTPUT="/opt/test-brew/bin/bash" mktest::stub_function bootstrap::brew::bash_path
  STUB_RETURN=1 mktest::stub_function bootstrap::bash::_binary_meets_floor "/opt/test-brew/bin/bash"
  STUB_EXIT=1 mktest::stub_function bootstrap::brew::_fail
  run bootstrap::bash::ensure_modern_bash
  [ "$status" -ne 0 ]
  mktest::assert_stub_called bootstrap::brew::_fail
}
