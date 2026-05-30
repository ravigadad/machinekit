#!/usr/bin/env bats
# Tests for lib/machinekit/input.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/input.sh
  source "$MACHINEKIT_DIR/lib/machinekit/input.sh"
  unset MACHINEKIT_TTY
}

# --- input::detect_mode ---

@test "detect_mode delegates to is_interactive and succeeds when interactive" {
  mktest::stub_function input::is_interactive
  input::detect_mode
  mktest::assert_stub_called input::is_interactive
}

@test "detect_mode delegates to is_interactive and succeeds even if non-interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  input::detect_mode
  mktest::assert_stub_called input::is_interactive
}

# --- input::is_interactive ---

@test "is_interactive returns cached true from context and exits 0" {
  STUB_OUTPUT="true" mktest::stub_function context::get "mode.interactive" "--coerce" "boolean"
  mktest::stub_function context::set
  touch "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(input::is_interactive)
  [ "$result" = "true" ]
  mktest::assert_stub_not_called context::set
}

@test "is_interactive returns cached false from context and exits 1" {
  STUB_OUTPUT="false" mktest::stub_function context::get "mode.interactive" "--coerce" "boolean"
  mktest::stub_function context::set
  run ! input::is_interactive
  mktest::assert_stub_not_called context::set
}

@test "is_interactive fails when context says true but tty is not readable" {
  STUB_OUTPUT="true" mktest::stub_function context::get "mode.interactive" "--coerce" "boolean"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/no-such-tty"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! input::is_interactive
  MATCH="tty" mktest::assert_stub_called lifecycle::fail
}

@test "is_interactive auto-detects true when tty is readable and caches it" {
  STUB_RETURN=1 mktest::stub_function context::get "mode.interactive" "--coerce" "boolean"
  mktest::stub_function context::set "mode.interactive" "true"
  touch "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(input::is_interactive)
  [ "$result" = "true" ]
  mktest::assert_stub_called context::set "mode.interactive" "true"
}

@test "is_interactive auto-detects false when tty is not readable and caches it" {
  STUB_RETURN=1 mktest::stub_function context::get "mode.interactive" "--coerce" "boolean"
  mktest::stub_function context::set "mode.interactive" "false"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/no-such-tty"
  run ! input::is_interactive
  mktest::assert_stub_called context::set "mode.interactive" "false"
}

# --- input::is_dry_run ---

@test "is_dry_run returns false when mode.dry_run is not set" {
  STUB_OUTPUT="false" mktest::stub_function context::get "mode.dry_run" "--coerce" "boolean" "--default" "false"
  run ! input::is_dry_run
}

@test "is_dry_run returns true when mode.dry_run is true" {
  STUB_OUTPUT="true" mktest::stub_function context::get "mode.dry_run" "--coerce" "boolean" "--default" "false"
  input::is_dry_run
}

@test "is_dry_run returns false when mode.dry_run is false" {
  STUB_OUTPUT="false" mktest::stub_function context::get "mode.dry_run" "--coerce" "boolean" "--default" "false"
  run ! input::is_dry_run
}

# --- input::command_exists ---

@test "command_exists returns true for bash" {
  input::command_exists bash
}

@test "command_exists returns false for a nonexistent command" {
  run ! input::command_exists __machinekit_nonexistent_cmd__
}
