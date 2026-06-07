#!/usr/bin/env bats
# Tests for lib/modules/orbstack.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/orbstack.sh
  source "$MACHINEKIT_DIR/lib/modules/orbstack.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
}

# --- orbstack::provides ---

@test "provides declares container_manager" {
  result=$(orbstack::provides)
  printf '%s\n' "$result" | grep -q '^container_manager$'
}

# --- orbstack::install ---

@test "install ensures orbstack is present via brew" {
  mktest::stub_function brew::install_formula "orbstack"
  orbstack::install
  mktest::assert_stub_called brew::install_formula "orbstack"
}
