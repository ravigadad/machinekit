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

@test "_current_meets_floor delegates the running version to the floor check" {
  mktest::stub_function bash_floor::meets "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
  bootstrap::bash::_current_meets_floor
  mktest::assert_stub_called bash_floor::meets "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
}

# --- bootstrap::bash::_binary_meets_floor ---

@test "_binary_meets_floor checks the binary's reported version against the floor" {
  STUB_OUTPUT="5 3" mktest::stub_function bootstrap::bash::_version_of "/fake/bash"
  mktest::stub_function bash_floor::meets "5" "3"
  bootstrap::bash::_binary_meets_floor /fake/bash
  mktest::assert_stub_called bash_floor::meets "5" "3"
}

@test "_binary_meets_floor treats an unreadable version as below the floor" {
  STUB_OUTPUT="" mktest::stub_function bootstrap::bash::_version_of "/fake/bash"
  mktest::stub_function bash_floor::meets "0" "0"
  bootstrap::bash::_binary_meets_floor /fake/bash
  mktest::assert_stub_called bash_floor::meets "0" "0"
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

@test "ensure_modern_bash reuses an already-installed brew bash without reinstalling" {
  local existing_brew_bash="$BATS_TEST_TMPDIR/bash"
  printf '#!/bin/sh\n' >"$existing_brew_bash"
  chmod +x "$existing_brew_bash"
  STUB_RETURN=1 mktest::stub_function bootstrap::bash::_current_meets_floor
  mktest::stub_function bootstrap::brew::ensure
  mktest::stub_function bootstrap::brew::install_bash
  STUB_OUTPUT="$existing_brew_bash" mktest::stub_function bootstrap::brew::bash_path
  mktest::stub_function bootstrap::bash::_binary_meets_floor "$existing_brew_bash"
  run bootstrap::bash::ensure_modern_bash
  [ "$status" -eq 0 ]
  [ "$output" = "$existing_brew_bash" ]
  mktest::assert_stub_not_called bootstrap::brew::install_bash
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
