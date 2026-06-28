#!/usr/bin/env bats
# Tests for lib/machinekit/modules.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/modules.sh
  source "$MACHINEKIT_DIR/lib/machinekit/modules.sh"
  unset _MK_MODULES_LOADED
  unset _MK_MODULES_SOURCED

  mktest::stub_function logging::step
  mktest::stub_function logging::debug
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  modules::run_installs() { echo "original"; }
  _MK_MODULES_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/modules.sh"
  [ "$(modules::run_installs)" = "original" ]
}

# --- modules::dir ---

@test "dir returns the path to the modules directory" {
  result=$(modules::dir)
  [ -d "$result" ]
  [[ "$result" == */modules ]]
}

# --- modules::source_all ---

@test "source_all makes module functions available" {
  modules::source_all
  declare -f age::install > /dev/null
}

@test "source_all makes capability module functions available" {
  modules::source_all
  declare -f tool_version_manager::is_capability > /dev/null
}

@test "source_all is idempotent" {
  modules::source_all
  age::install() { echo "sentinel"; }
  modules::source_all
  [ "$(age::install)" = "sentinel" ]
}

# --- modules::run_preflights ---

@test "run_preflights calls preflight for modules that declare it" {
  mktest::stub_function modules::_call_function_per_module "preflight"
  modules::run_preflights
  mktest::assert_stub_called modules::_call_function_per_module "preflight"
}

# --- modules::run_installs ---

@test "run_installs calls install for modules that declare it" {
  mktest::stub_function modules::_call_function_per_module "install"
  modules::run_installs
  mktest::assert_stub_called modules::_call_function_per_module "install"
}

# --- modules::run_post_apply ---

@test "run_post_apply calls post_apply for modules that declare it" {
  mktest::stub_function modules::_call_function_per_module "post_apply"
  modules::run_post_apply
  mktest::assert_stub_called modules::_call_function_per_module "post_apply"
}

@test "_call_function_per_module calls given function for all modules that declare it" {
  mktest::stub_function modules::source_all
  mktest::stub_function foo_module::test
  mktest::stub_function bar_module::test
  STUB_OUTPUT=$'foo_module\nbar_module\nbaz_module' mktest::stub_function context::get_array "modules.active"
  modules::_call_function_per_module "test"
  mktest::assert_stub_called modules::source_all
  mktest::assert_stub_called foo_module::test
  mktest::assert_stub_called bar_module::test
}

# --- modules::collect ---

@test "collect runs the named hook across modules and forwards their output" {
  STUB_OUTPUT=$'the_result' \
    mktest::stub_function modules::_call_function_per_module "pool_secrets"
  run modules::collect pool_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'the_result' ]
}

# --- modules::capability_active ---

@test "capability_active is true when an active module provides the capability" {
  fake_runtime::provides() { printf 'container_manager\n'; }
  STUB_OUTPUT="fake_runtime" mktest::stub_function context::get_array "modules.active"
  modules::capability_active container_manager
}

@test "capability_active is false when an active provider offers a different capability" {
  fake_runtime::provides() { printf 'something_else\n'; }
  STUB_OUTPUT="fake_runtime" mktest::stub_function context::get_array "modules.active"
  run ! modules::capability_active container_manager
}

@test "capability_active is false when no active module declares provides" {
  STUB_OUTPUT="plain_module" mktest::stub_function context::get_array "modules.active"
  run ! modules::capability_active container_manager
}
