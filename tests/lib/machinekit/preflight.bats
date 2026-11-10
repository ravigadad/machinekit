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

@test "run resolves inputs, readies the secrets manager, builds staging, then runs module preflights" {
  mktest::stub_function preflight::resolve_inputs
  mktest::stub_function secrets_manager::ensure_ready
  mktest::stub_function secrets::assert_age_key_not_pooled
  mktest::stub_function home::transforms::register_from_modules
  mktest::stub_function home::staging::build
  mktest::stub_function modules::run_preflights
  preflight::run
  # Ordered: inputs resolve first; the secrets manager is readied before module
  # preflights, which ask whether their secrets exist; the age-key-not-pooled
  # invariant is asserted in the main shell (where its lifecycle::fail can halt);
  # the transform registry and staging tree are built from the resolved active
  # set; and the module preflights query the staging tree (via will_exist), so it
  # must exist before they run.
  mktest::assert_stub_called_in_order preflight::resolve_inputs
  mktest::assert_stub_called_in_order secrets_manager::ensure_ready
  mktest::assert_stub_called_in_order secrets::assert_age_key_not_pooled
  mktest::assert_stub_called_in_order home::transforms::register_from_modules
  mktest::assert_stub_called_in_order home::staging::build
  mktest::assert_stub_called_in_order modules::run_preflights
}

# --- preflight::resolve_inputs ---

@test "resolve_inputs detects, fetches, and resolves machine type, config, and active modules" {
  mktest::stub_function system::detect
  mktest::stub_function blueprints::fetch
  mktest::stub_function preflight::resolve_machine_type
  mktest::stub_function config::load
  mktest::stub_function preflight::resolve_active_modules
  preflight::resolve_inputs
  # Ordered: config reads the fetched blueprint and the resolved machine type;
  # the active module set is then computed from that config.
  mktest::assert_stub_called_in_order system::detect
  mktest::assert_stub_called_in_order blueprints::fetch
  mktest::assert_stub_called_in_order preflight::resolve_machine_type
  mktest::assert_stub_called_in_order config::load
  mktest::assert_stub_called_in_order preflight::resolve_active_modules
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

@test "resolve_machine_type stops when reading the machine type fails" {
  STUB_EXIT=97 mktest::stub_function context::get "machine_type" --prompt "Which machine type do you want to apply?" --default ""
  run preflight::resolve_machine_type
  [ "$status" -eq 97 ]
}

# --- preflight::resolve_active_modules ---

# Base modules are always active, so an empty requested set still resolves to
# the base set — never to nothing. Fake base names keep this decoupled from the
# current real value of MK_BASE_MODULES.
@test "resolve_active_modules resolves the base set even when none are requested" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_OUTPUT='{"fake":"config"}' mktest::stub_function config::get_json "" "{}"
  STUB_OUTPUT='[]' mktest::stub_function config::extended_list '{"fake":"config"}' "modules" "after" "machinekit.toml"
  STUB_OUTPUT=$'bm1\nbm2\ndep' mktest::stub_function resolver::resolve bm1 bm2
  mktest::stub_function context::set_array "modules.active" bm1 bm2 dep
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 dep
}

@test "resolve_active_modules stops when reading the config fails" {
  STUB_EXIT=97 mktest::stub_function config::get_json "" "{}"
  STUB_OUTPUT='[]' mktest::stub_function config::extended_list
  STUB_OUTPUT='fake-module' mktest::stub_function resolver::resolve
  mktest::stub_function context::set_array
  run preflight::resolve_active_modules
  [ "$status" -eq 97 ]
}

@test "resolve_active_modules stops when reading the module list fails" {
  STUB_OUTPUT='{"fake":"config"}' mktest::stub_function config::get_json "" "{}"
  STUB_EXIT=97 mktest::stub_function config::extended_list
  run preflight::resolve_active_modules
  [ "$status" -eq 97 ]
}

# A machine type adds to common's modules with additional_modules, since the config
# merge would otherwise replace the list whole; extended_list owns that combination.
@test "resolve_active_modules resolves the base set unioned with modules and additional_modules" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_OUTPUT='{"fake":"config"}' mktest::stub_function config::get_json "" "{}"
  STUB_OUTPUT='["foo","bar","extra1"]' mktest::stub_function config::extended_list '{"fake":"config"}' "modules" "after" "machinekit.toml"
  STUB_OUTPUT=$'bm1\nbm2\nfoo\nbar\nextra1\nbaz' mktest::stub_function resolver::resolve bm1 bm2 foo bar extra1
  mktest::stub_function context::set_array "modules.active" bm1 bm2 foo bar extra1 baz
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 foo bar extra1 baz
}
@test "resolve_active_modules stops when resolving the modules fails" {
  STUB_OUTPUT='{"fake":"config"}' mktest::stub_function config::get_json "" "{}"
  STUB_OUTPUT='[]' mktest::stub_function config::extended_list
  STUB_EXIT=97 mktest::stub_function resolver::resolve
  run preflight::resolve_active_modules
  [ "$status" -eq 97 ]
}

