#!/usr/bin/env bats
# Tests for lib/modules/docker_ce.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/docker_ce.sh
  source "$MACHINEKIT_DIR/lib/modules/docker_ce.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
}

# --- docker_ce::provides ---

@test "provides declares container_manager" {
  result=$(docker_ce::provides)
  printf '%s\n' "$result" | grep -q '^container_manager$'
}

# --- docker_ce::install ---

@test "install skips the install script when docker is already present" {
  mktest::stub_function input::command_exists
  mktest::stub_function docker_ce::_run_install_script
  docker_ce::install
  mktest::assert_stub_not_called docker_ce::_run_install_script
}

@test "install in dry-run logs a dry_run message" {
  STUB_RETURN=1 mktest::stub_function input::command_exists
  mktest::stub_function input::is_dry_run
  mktest::stub_function docker_ce::_run_install_script
  docker_ce::install
  mktest::assert_stub_called logging::dry_run
}

@test "install in dry-run does not run install script" {
  STUB_RETURN=1 mktest::stub_function input::command_exists
  mktest::stub_function input::is_dry_run
  mktest::stub_function docker_ce::_run_install_script
  docker_ce::install
  mktest::assert_stub_not_called docker_ce::_run_install_script
}

@test "install in real mode runs install script" {
  STUB_RETURN=1 mktest::stub_function input::command_exists
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function docker_ce::_run_install_script
  docker_ce::install
  mktest::assert_stub_called docker_ce::_run_install_script
}
