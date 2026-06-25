#!/usr/bin/env bats
# Tests for lib/modules/codex.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/codex.sh
  source "$MACHINEKIT_DIR/lib/modules/codex.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
}

# --- codex::install ---

@test "install skips the installer when codex is already present" {
  mktest::stub_function input::command_exists codex
  mktest::stub_function codex::_run_installer
  codex::install
  mktest::assert_stub_not_called codex::_run_installer
}

@test "install in dry-run logs a dry_run message and does not run the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists codex
  mktest::stub_function input::is_dry_run
  mktest::stub_function codex::_run_installer
  codex::install
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called codex::_run_installer
}

@test "install in real mode runs the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists codex
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function codex::_run_installer
  codex::install
  mktest::assert_stub_called codex::_run_installer
}

# --- codex::_run_installer ---

@test "_run_installer fetches the official installer over curl" {
  local capture; capture=$(mktemp)
  curl() { printf '%s' "$*" > "$capture"; }
  codex::_run_installer
  [ "$(cat "$capture")" = "-fsSL https://chatgpt.com/codex/install.sh" ]
}
