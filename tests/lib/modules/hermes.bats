#!/usr/bin/env bats
# Tests for lib/modules/hermes.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/hermes.sh
  source "$MACHINEKIT_DIR/lib/modules/hermes.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
}

# --- hermes::after ---

@test "after declares the tool_version_manager soft-order edge" {
  run hermes::after
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tool_version_manager" ]
}

# --- hermes::install ---

@test "install skips the installer when hermes is already present" {
  mktest::stub_function input::command_exists hermes
  mktest::stub_function hermes::_run_installer
  hermes::install
  mktest::assert_stub_not_called hermes::_run_installer
}

@test "install in dry-run logs a dry_run message and does not run the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists hermes
  mktest::stub_function input::is_dry_run
  mktest::stub_function hermes::_run_installer
  hermes::install
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called hermes::_run_installer
}

@test "install in real mode runs the installer" {
  STUB_RETURN=1 mktest::stub_function input::command_exists hermes
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hermes::_run_installer
  hermes::install
  mktest::assert_stub_called hermes::_run_installer
}

# --- hermes::_run_installer ---

@test "_run_installer routes the vendor installer through the version manager with node" {
  mktest::stub_function tool_version_manager::exec node@latest bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
  hermes::_run_installer
  mktest::assert_stub_called tool_version_manager::exec node@latest bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
}
