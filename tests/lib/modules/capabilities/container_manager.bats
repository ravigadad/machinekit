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

@test "requires outputs the default_satisfier" {
  STUB_OUTPUT="some-satisfier" mktest::stub_function container_manager::default_satisfier
  result=$(container_manager::requires)
  [ "$result" = "some-satisfier" ]
}

# --- container_manager::install ---

@test "install is a no-op" {
  run container_manager::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- container_manager::ensure_network ---

@test "ensure_network does not create the network when it already exists" {
  mktest::stub_function container_manager::_docker "network" "inspect" "machinekit"
  mktest::stub_function container_manager::_docker "network" "create" "machinekit"
  container_manager::ensure_network
  mktest::assert_stub_not_called container_manager::_docker "network" "create" "machinekit"
}

@test "ensure_network creates the machinekit network when absent" {
  STUB_RETURN=1 mktest::stub_function container_manager::_docker "network" "inspect" "machinekit"
  mktest::stub_function container_manager::_docker "network" "create" "machinekit"
  container_manager::ensure_network
  mktest::assert_stub_called container_manager::_docker "network" "create" "machinekit"
}

# --- container_manager::container_subnet ---

@test "container_subnet ensures the network, then returns its subnet" {
  mktest::stub_function container_manager::ensure_network
  STUB_OUTPUT="172.30.0.0/16" mktest::stub_function container_manager::_docker \
    "network" "inspect" "machinekit" "--format" "{{ (index .IPAM.Config 0).Subnet }}"
  run container_manager::container_subnet
  [ "$output" = "172.30.0.0/16" ]
  mktest::assert_stub_called container_manager::ensure_network
}

# --- container_manager::host_alias ---

@test "host_alias returns the container-to-host DNS name" {
  run container_manager::host_alias
  [ "$output" = "host.docker.internal" ]
}

# --- container_manager::_docker ---

@test "_docker runs docker under sudo on Linux" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  mktest::stub_function sudo "docker" "network" "ls"
  container_manager::_docker network ls
  mktest::assert_stub_called sudo "docker" "network" "ls"
}

@test "_docker runs docker directly on macOS" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  mktest::stub_function docker "network" "ls"
  container_manager::_docker network ls
  mktest::assert_stub_called docker "network" "ls"
}
