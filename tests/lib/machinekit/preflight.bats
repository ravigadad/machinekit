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
  mktest::stub_function age::assert_key_source_type
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
  mktest::assert_stub_called_in_order age::assert_key_source_type
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

# --- preflight::resolve_active_modules ---

# Base modules are always active, so an empty requested set still resolves to
# the base set — never to nothing. Fake base names keep this decoupled from the
# current real value of MK_BASE_MODULES.
@test "resolve_active_modules resolves the base set even when none are requested" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_OUTPUT="" mktest::stub_function config::get_array "modules"
  STUB_OUTPUT="" mktest::stub_function config::get_array "additional_modules"
  STUB_OUTPUT=$'bm1\nbm2\ndep' mktest::stub_function resolver::resolve bm1 bm2
  mktest::stub_function context::set_array "modules.active" bm1 bm2 dep
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 dep
}

@test "resolve_active_modules resolves the base set unioned with the requested modules" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function config::get_array "modules"
  STUB_OUTPUT="" mktest::stub_function config::get_array "additional_modules"
  STUB_OUTPUT=$'bm1\nbm2\nfoo\nbar\nbaz' mktest::stub_function resolver::resolve bm1 bm2 foo bar
  mktest::stub_function context::set_array "modules.active" bm1 bm2 foo bar baz
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 foo bar baz
}

# additional_modules extends the requested set rather than replacing it: a machine
# type sets it to add a few modules on top of common's, which the config merge would
# otherwise have it replace wholesale. Both keys feed the resolver, common's first.
@test "resolve_active_modules appends additional_modules onto the requested set" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function config::get_array "modules"
  STUB_OUTPUT=$'extra1\nextra2' mktest::stub_function config::get_array "additional_modules"
  STUB_OUTPUT=$'bm1\nbm2\nfoo\nbar\nextra1\nextra2\nbaz' \
    mktest::stub_function resolver::resolve bm1 bm2 foo bar extra1 extra2
  mktest::stub_function context::set_array "modules.active" bm1 bm2 foo bar extra1 extra2 baz
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 foo bar extra1 extra2 baz
}

# The two keys are read independently, so additional_modules contributes even when
# no `modules` list is inherited — it is not a sub-clause of `modules` being set. An
# absent key makes config::get_array return non-zero (STUB_RETURN), which must not
# suppress the second read.
@test "resolve_active_modules reads additional_modules even with no modules list" {
  MK_BASE_MODULES=(bm1 bm2)
  STUB_RETURN=1 mktest::stub_function config::get_array "modules"
  STUB_OUTPUT=$'extra1\nextra2' mktest::stub_function config::get_array "additional_modules"
  STUB_OUTPUT=$'bm1\nbm2\nextra1\nextra2' mktest::stub_function resolver::resolve bm1 bm2 extra1 extra2
  mktest::stub_function context::set_array "modules.active" bm1 bm2 extra1 extra2
  preflight::resolve_active_modules
  mktest::assert_stub_called context::set_array "modules.active" bm1 bm2 extra1 extra2
}
