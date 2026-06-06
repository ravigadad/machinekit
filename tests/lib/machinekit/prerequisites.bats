#!/usr/bin/env bats
# Tests for lib/machinekit/prerequisites.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/prerequisites.sh
  source "$MACHINEKIT_DIR/lib/machinekit/prerequisites.sh"

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
}

# --- prerequisites::install ---

@test "install passes every prerequisite to _install_tool" {
  mktest::stub_function prerequisites::_install_tool
  prerequisites::install
  mktest::assert_stub_called prerequisites::_install_tool "jq"
  mktest::assert_stub_called prerequisites::_install_tool "toml2json"
  mktest::assert_stub_called prerequisites::_install_tool "gomplate"
  mktest::assert_stub_called prerequisites::_install_tool "git"
  mktest::assert_stub_not_called prerequisites::_install_tool "age"
}

# --- prerequisites::_install_tool ---

@test "_install_tool delegates to brew::install_formula with --override-dry-run" {
  mktest::stub_function brew::install_formula "git" "--override-dry-run"
  prerequisites::_install_tool "git"
  mktest::assert_stub_called brew::install_formula "git" "--override-dry-run"
}
