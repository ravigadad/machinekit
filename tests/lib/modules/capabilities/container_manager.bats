#!/usr/bin/env bats
# Tests for lib/modules/capabilities/container_manager.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/capabilities/container_manager.sh
  source "$MACHINEKIT_DIR/lib/modules/capabilities/container_manager.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::warn
}

# --- container_manager::is_capability ---

@test "is_capability returns 0" {
  container_manager::is_capability
}

# --- container_manager::default_satisfier ---

@test "default_satisfier outputs orbstack on darwin" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  result=$(container_manager::default_satisfier)
  [ "$result" = "orbstack" ]
}

@test "default_satisfier outputs docker_ce on linux" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  result=$(container_manager::default_satisfier)
  [ "$result" = "docker_ce" ]
}

@test "default_satisfier fails on unknown platform" {
  STUB_OUTPUT="windows" mktest::stub_function context::get "os.family"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run container_manager::default_satisfier
  [ "$status" -ne 0 ]
}

# --- container_manager::requires ---

@test "requires outputs orbstack on darwin" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  result=$(container_manager::requires)
  [ "$result" = "orbstack" ]
}

@test "requires outputs docker_ce on linux" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  result=$(container_manager::requires)
  [ "$result" = "docker_ce" ]
}

# --- container_manager::install ---

@test "install is a no-op" {
  run container_manager::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
