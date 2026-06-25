#!/usr/bin/env bats
# Tests for lib/modules/opencode.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/opencode.sh
  source "$MACHINEKIT_DIR/lib/modules/opencode.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
}

# --- opencode::install ---

@test "install skips the installer when opencode is already present" {
  mktest::stub_function input::command_exists opencode
  mktest::stub_function opencode::_run_installer
  opencode::install
  mktest::assert_stub_not_called opencode::_run_installer
}

@test "install in dry-run logs a dry_run message and does not run the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists opencode
  mktest::stub_function input::is_dry_run
  mktest::stub_function opencode::_run_installer
  opencode::install
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called opencode::_run_installer
}

@test "install in real mode runs the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists opencode
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function opencode::_run_installer
  opencode::install
  mktest::assert_stub_called opencode::_run_installer
}

# --- opencode::_run_installer ---

@test "_run_installer fetches the official installer over curl" {
  local capture; capture=$(mktemp)
  curl() { printf '%s' "$*" > "$capture"; }
  opencode::_run_installer
  [ "$(cat "$capture")" = "-fsSL https://opencode.ai/install" ]
}
