#!/usr/bin/env bats
# Tests for lib/machinekit/modules.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/modules.sh
  source "$MACHINEKIT_DIR/lib/machinekit/modules.sh"
  unset _MK_MODULES_LOADED
  unset _MK_MODULES_SOURCED

  mktest::stub_function logging::step
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

@test "source_all is idempotent" {
  modules::source_all
  age::install() { echo "sentinel"; }
  modules::source_all
  [ "$(age::install)" = "sentinel" ]
}

# --- modules::run_preflights ---

@test "run_preflights calls preflight for modules that declare it" {
  mktest::stub_function modules::source_all
  STUB_OUTPUT=$'age\nzsh\ngit' mktest::stub_function context::get_array "modules.active"
  mktest::stub_function age::preflight
  mktest::stub_function git::preflight
  modules::run_preflights
  mktest::assert_stub_called age::preflight
  mktest::assert_stub_called git::preflight
}

@test "run_preflights skips modules with no preflight function" {
  mktest::stub_function modules::source_all
  STUB_OUTPUT=$'zsh' mktest::stub_function context::get_array "modules.active"
  modules::run_preflights
}

# --- modules::run_installs ---

@test "run_installs calls install for each active module in order" {
  mktest::stub_function modules::source_all
  STUB_OUTPUT=$'age\nmise' mktest::stub_function context::get_array "modules.active"
  mktest::stub_function age::install
  mktest::stub_function mise::install
  modules::run_installs
  mktest::assert_stub_called age::install
  mktest::assert_stub_called mise::install
}
