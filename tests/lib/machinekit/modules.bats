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

@test "source_all sources every module file" {
  printf 'fake_one::hook() { echo one; }\n' > "$BATS_TEST_TMPDIR/fake_one.sh"
  printf 'fake_two::hook() { echo two; }\n' > "$BATS_TEST_TMPDIR/fake_two.sh"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/fake_one.sh"$'\n'"$BATS_TEST_TMPDIR/fake_two.sh" mktest::stub_function modules::_files
  modules::source_all
  [ "$(fake_one::hook)" = "one" ]
  [ "$(fake_two::hook)" = "two" ]
}

@test "source_all is idempotent" {
  printf 'fake_one::hook() { echo one; }\n' > "$BATS_TEST_TMPDIR/fake_one.sh"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/fake_one.sh" mktest::stub_function modules::_files
  modules::source_all
  fake_one::hook() { echo "sentinel"; }
  modules::source_all
  [ "$(fake_one::hook)" = "sentinel" ]
}

# --- modules::_files ---

@test "_files lists the top-level module files and the capability satisfiers" {
  _MK_MODULES_DIR="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$_MK_MODULES_DIR/capabilities" "$_MK_MODULES_DIR/foo_module"
  : > "$_MK_MODULES_DIR/foo_module.sh"
  : > "$_MK_MODULES_DIR/foo_module/helper.sh"
  : > "$_MK_MODULES_DIR/capabilities/baz_module.sh"
  run modules::_files
  [ "$status" -eq 0 ]
  [ "$output" = "$_MK_MODULES_DIR/foo_module.sh"$'\n'"$_MK_MODULES_DIR/capabilities/baz_module.sh" ]
}

@test "_files finds the real modules, capability satisfiers included" {
  run modules::_files
  [[ "$output" == *"/modules/age.sh"* ]]
  [[ "$output" == *"/modules/capabilities/tool_version_manager.sh"* ]]
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

@test "_call_function_per_module calls the function on each active module that defines it and forwards the results" {
  STUB_OUTPUT="foo_output" mktest::stub_function foo_module::test
  STUB_OUTPUT="bar_output" mktest::stub_function bar_module::test
  STUB_OUTPUT=$'foo_module\nbar_module' mktest::stub_function modules::active_defining "test"
  run modules::_call_function_per_module "test"
  [ "$output" = $'foo_output\nbar_output' ]
}

@test "_call_function_per_module runs every module even when one reads all of its standard input" {
  # A brew cask upgrade can run a script that reads stdin, as OrbStack's did.
  foo_module::test() { cat > /dev/null; printf 'foo_ran\n'; }
  STUB_OUTPUT="bar_ran" mktest::stub_function bar_module::test
  STUB_OUTPUT=$'foo_module\nbar_module' mktest::stub_function modules::active_defining "test"
  run modules::_call_function_per_module "test" < /dev/null
  [ "$output" = $'foo_ran\nbar_ran' ]
}

@test "_call_function_per_module stops when listing the active modules fails" {
  STUB_EXIT=97 mktest::stub_function modules::active_defining "test"
  run modules::_call_function_per_module "test"
  [ "$status" -eq 97 ]
}

# --- modules::collect ---

@test "collect runs the named hook across modules and forwards their output" {
  STUB_OUTPUT=$'the_result' \
    mktest::stub_function modules::_call_function_per_module "declared_secrets"
  run modules::collect declared_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'the_result' ]
}

# --- modules::active_defining ---

@test "active_defining lists the active modules that define the hook, in order" {
  mktest::stub_function foo_module::the_hook
  mktest::stub_function baz_module::the_hook
  STUB_OUTPUT=$'foo_module\nbar_module\nbaz_module' mktest::stub_function context::get_array "modules.active"
  run modules::active_defining the_hook
  [ "$status" -eq 0 ]
  [ "$output" = $'foo_module\nbaz_module' ]
}

@test "active_defining lists nothing when no module is active" {
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  run modules::active_defining the_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "active_defining stops when reading the active modules fails" {
  STUB_EXIT=97 mktest::stub_function context::get_array "modules.active"
  run modules::active_defining the_hook
  [ "$status" -eq 97 ]
}

# --- modules::defining ---

@test "defining lists every module that defines the hook, active or not" {
  STUB_OUTPUT="/fake/modules/foo_module.sh"$'\n'"/fake/modules/bar_module.sh"$'\n'"/fake/modules/capabilities/baz_module.sh" \
    mktest::stub_function modules::_files
  mktest::stub_function foo_module::the_hook
  mktest::stub_function baz_module::the_hook
  run modules::defining the_hook
  [ "$status" -eq 0 ]
  [ "$output" = $'foo_module\nbaz_module' ]
}

# --- modules::capability_active ---

@test "capability_active is true when capability_satisfier finds a satisfier" {
  STUB_OUTPUT="fake_runtime" mktest::stub_function modules::capability_satisfier container_manager
  modules::capability_active container_manager
}

@test "capability_active is false when capability_satisfier finds none" {
  STUB_RETURN=1 mktest::stub_function modules::capability_satisfier container_manager
  run ! modules::capability_active container_manager
}

# --- modules::capability_satisfier ---

@test "capability_satisfier returns the name of the active module providing the capability" {
  fake_runtime::provides() { printf 'secrets_manager\n'; }
  STUB_OUTPUT="fake_runtime" mktest::stub_function modules::active_defining provides
  run modules::capability_satisfier secrets_manager
  [ "$output" = "fake_runtime" ]
}

@test "capability_satisfier is empty when no active module provides any capability" {
  STUB_OUTPUT="" mktest::stub_function modules::active_defining provides
  run modules::capability_satisfier secrets_manager
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "capability_satisfier skips an active module that provides a different capability" {
  fake_runtime::provides() { printf 'container_manager\n'; }
  STUB_OUTPUT="fake_runtime" mktest::stub_function modules::active_defining provides
  run modules::capability_satisfier secrets_manager
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "capability_satisfier stops when listing the providing modules fails" {
  STUB_EXIT=97 mktest::stub_function modules::active_defining provides
  run modules::capability_satisfier secrets_manager
  [ "$status" -eq 97 ]
}
