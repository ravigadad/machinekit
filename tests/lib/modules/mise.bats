#!/usr/bin/env bats
# Tests for lib/modules/mise.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/mise.sh
  source "$MACHINEKIT_DIR/lib/modules/mise.sh"

  # Logging collaborators — allow-only; logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::warn
  mktest::stub_function logging::dry_run
}

# --- mise::provides ---

@test "provides declares tool_version_manager" {
  result=$(mise::provides)
  printf '%s\n' "$result" | grep -q '^tool_version_manager$'
}

# --- mise::requires ---

@test "requires declares zsh as a dependency" {
  result=$(mise::requires)
  printf '%s\n' "$result" | grep -q '^zsh$'
}

# --- mise::install ---

@test "install ensures mise is present via brew" {
  mktest::stub_function brew::install_formula "mise"
  mise::install
  mktest::assert_stub_called brew::install_formula "mise"
}

# --- mise::post_apply ---

@test "post_apply runs mise install" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function mise "install"
  mise::post_apply
  mktest::assert_stub_called mise "install"
}

@test "post_apply in dry-run logs and does not run mise install" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function mise "install"
  mise::post_apply
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called mise "install"
}

@test "post_apply continues when mise install reports an error" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function mise "install"
  run mise::post_apply
  [ "$status" -eq 0 ]
}
