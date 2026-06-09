#!/usr/bin/env bats
# Tests for lib/modules/zsh.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/zsh.sh
  source "$MACHINEKIT_DIR/lib/modules/zsh.sh"

  mktest::stub_function logging::step
}

# --- zsh::install ---

@test "install ensures zsh is present via brew" {
  mktest::stub_function brew::install_formula "zsh"
  zsh::install
  mktest::assert_stub_called brew::install_formula "zsh"
}
