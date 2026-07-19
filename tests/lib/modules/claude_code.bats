#!/usr/bin/env bats
# Tests for lib/modules/claude_code.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/claude_code.sh
  source "$MACHINEKIT_DIR/lib/modules/claude_code.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
}

# --- claude_code::install ---

@test "install skips the installer when claude is already present" {
  mktest::stub_function input::command_exists claude
  mktest::stub_function claude_code::_run_installer
  claude_code::install
  mktest::assert_stub_not_called claude_code::_run_installer
}

@test "install in dry-run logs a dry_run message and does not run the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists claude
  mktest::stub_function input::is_dry_run
  mktest::stub_function claude_code::_run_installer
  claude_code::install
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called claude_code::_run_installer
}

@test "install in real mode runs the installer and records the fresh install" {
  STUB_RETURN=1 mktest::stub_function input::command_exists claude
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function claude_code::_run_installer
  mktest::stub_function context::set
  claude_code::install
  mktest::assert_stub_called claude_code::_run_installer
  mktest::assert_stub_called context::set claude_code.installed true
}

# --- claude_code::postflight_instructions ---

@test "postflight_instructions surfaces the sign-in step after a fresh install" {
  STUB_OUTPUT="true" mktest::stub_function context::get "claude_code.installed" --default false
  run claude_code::postflight_instructions
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"sign in"* ]]
}

@test "postflight_instructions emits nothing when the CLI was already present" {
  STUB_OUTPUT="false" mktest::stub_function context::get "claude_code.installed" --default false
  run claude_code::postflight_instructions
  [ -z "$output" ]
}

# --- claude_code::_run_installer ---

@test "_run_installer fetches the official installer over curl" {
  # Capture the real curl invocation with a fake (the call is inside a pipe, and
  # the fake's empty stdout keeps anything from reaching the piped shell).
  local capture; capture=$(mktemp)
  curl() { printf '%s' "$*" > "$capture"; }
  claude_code::_run_installer
  [ "$(cat "$capture")" = "-fsSL https://claude.ai/install.sh" ]
}
