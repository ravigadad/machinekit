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
  mktest::stub_function config::load
  mktest::stub_function preflight::resolve_machine_type
  mktest::stub_function preflight::resolve_active_modules
  mktest::stub_function modules::run_preflights
  preflight::run
  mktest::assert_stub_called system::detect
  mktest::assert_stub_called blueprints::fetch
  mktest::assert_stub_called config::load
  mktest::assert_stub_called preflight::resolve_machine_type
  mktest::assert_stub_called preflight::resolve_active_modules
  mktest::assert_stub_called modules::run_preflights
}

# --- preflight::resolve_machine_type ---

@test "resolve_machine_type gets the machine type from context (or prompts), and logs it" {
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type" --prompt "Which machine type do you want to apply?" --default ""
  preflight::resolve_machine_type
  MATCH="laptop" mktest::assert_stub_called logging::info
}

@test "resolve_machine_type reports non-specified if not in context" {
  # The || true guard lets preflight proceed even when machine_type is absent.
  STUB_RETURN=1 mktest::stub_function context::get "machine_type" --prompt "Which machine type do you want to apply?" --default ""
  run preflight::resolve_machine_type
  MATCH="not specified" mktest::assert_stub_called logging::info
}

# --- preflight::resolve_active_modules ---

@test "resolve_active_modules handles empty modules list gracefully" {
  STUB_OUTPUT="" mktest::stub_function config::get_array "modules"
  mktest::stub_function resolver::resolve
  mktest::stub_function context::set_array
  run preflight::resolve_active_modules
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called resolver::resolve
}

@test "resolve_active_modules reads modules from config and stores resolved order" {
  STUB_OUTPUT=$'home\nzsh\nmise' mktest::stub_function config::get_array "modules"
  STUB_OUTPUT=$'home\nzsh\nmise' mktest::stub_function resolver::resolve home zsh mise
  mktest::stub_function context::set_array "modules.active" home zsh mise
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" home zsh mise
}
