#!/usr/bin/env bats
# Tests for lib/machinekit/preflight.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/preflight.sh
  source "$MACHINEKIT_DIR/lib/machinekit/preflight.sh"
  unset _MK_PREFLIGHT_LOADED

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::success
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  preflight::run() { echo "original"; }
  _MK_PREFLIGHT_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/preflight.sh"
  [ "$(preflight::run)" = "original" ]
}

# --- preflight::run ---

@test "run calls all steps" {
  mktest::stub_function system::detect
  mktest::stub_function blueprints::fetch
  mktest::stub_function preflight::report_machine_type
  mktest::stub_function preflight::resolve_active_modules
  mktest::stub_function preflight::run_module_preflights
  preflight::run
  mktest::assert_stub_called system::detect
  mktest::assert_stub_called blueprints::fetch
  mktest::assert_stub_called preflight::report_machine_type
  mktest::assert_stub_called preflight::resolve_active_modules
  mktest::assert_stub_called preflight::run_module_preflights
}

# --- preflight::report_machine_type ---

@test "report_machine_type logs the machine type from context" {
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  preflight::report_machine_type
  MATCH="laptop" mktest::assert_stub_called logging::info
}

@test "report_machine_type reports non-specified if not in context" {
  # The || true guard lets preflight proceed even when machine_type is absent.
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  run preflight::report_machine_type
  MATCH="not specified" mktest::assert_stub_called logging::info
}

# --- preflight::resolve_active_modules ---

@test "resolve_active_modules stores the expected module list" {
  mktest::stub_function context::set_array "modules.active" age brewfile home git mise zsh
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" age brewfile home git mise zsh
}

# --- preflight::run_module_preflights ---

@test "run_module_preflights calls age and git preflight" {
  mktest::stub_function age::preflight
  mktest::stub_function git::preflight
  preflight::run_module_preflights
  mktest::assert_stub_called age::preflight
  mktest::assert_stub_called git::preflight
}
