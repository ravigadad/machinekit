#!/usr/bin/env bats
# Tests for lib/modules/openclaw.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/openclaw.sh
  source "$MACHINEKIT_DIR/lib/modules/openclaw.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
}

# --- openclaw::after ---

@test "after declares the tool_version_manager soft-order edge" {
  run openclaw::after
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tool_version_manager" ]
}

# --- openclaw::install ---

@test "install skips the installer when openclaw is already present" {
  mktest::stub_function input::command_exists openclaw
  mktest::stub_function openclaw::_run_installer
  openclaw::install
  mktest::assert_stub_not_called openclaw::_run_installer
}

@test "install in dry-run logs a dry_run message and does not run the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists openclaw
  mktest::stub_function input::is_dry_run
  mktest::stub_function openclaw::_run_installer
  openclaw::install
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called openclaw::_run_installer
}

@test "install in real mode runs the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists openclaw
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function openclaw::_run_installer
  openclaw::install
  mktest::assert_stub_called openclaw::_run_installer
}

# --- openclaw::_run_installer ---

@test "_run_installer routes the vendor installer through the version manager with node" {
  mktest::stub_function tool_version_manager::exec node@latest bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --install-method git'
  openclaw::_run_installer
  mktest::assert_stub_called tool_version_manager::exec node@latest bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --install-method git'
}
