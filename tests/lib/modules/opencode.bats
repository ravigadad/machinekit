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

@test "install in real mode runs the installer and records the fresh install" {
  STUB_RETURN=1 mktest::stub_function input::command_exists opencode
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function opencode::_run_installer
  mktest::stub_function context::set
  opencode::install
  mktest::assert_stub_called opencode::_run_installer
  mktest::assert_stub_called context::set opencode.installed true
}

# --- opencode::postflight_instructions ---

@test "postflight_instructions surfaces the setup step after a fresh install" {
  STUB_OUTPUT="true" mktest::stub_function context::get "opencode.installed" --default false
  run opencode::postflight_instructions
  [[ "$output" == *"opencode"* ]]
  [[ "$output" == *"provider config"* ]]
}

@test "postflight_instructions emits nothing when the CLI was already present" {
  STUB_OUTPUT="false" mktest::stub_function context::get "opencode.installed" --default false
  run opencode::postflight_instructions
  [ -z "$output" ]
}

# --- opencode::_run_installer ---

@test "_run_installer fetches the official installer over curl" {
  local capture; capture=$(mktemp)
  curl() { printf '%s' "$*" > "$capture"; }
  opencode::_run_installer
  [ "$(cat "$capture")" = "-fsSL https://opencode.ai/install" ]
}
