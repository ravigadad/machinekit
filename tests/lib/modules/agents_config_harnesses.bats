#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/agents_config_harnesses.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::dry_run
}

# --- requires ---

@test "requires invokes each configured harness's requires" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::foo::requires
  mktest::stub_function agents_config_harnesses::bar::requires
  agents_config_harnesses::requires
  mktest::assert_stub_called agents_config_harnesses::foo::requires
  mktest::assert_stub_called agents_config_harnesses::bar::requires
}

@test "requires returns success even when a configured harness declares no requires" {
  # Neither 'foo' nor 'bar' has a submodule, so no ::requires function — the
  # loop's last command (the failing declare -F) must not become the return
  # value. Strip the `return 0` pin and this goes red.
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  run agents_config_harnesses::requires
  [ "$status" -eq 0 ]
}

@test "requires is a clean no-op when no harnesses are configured" {
  mktest::stub_function agents_config_harnesses::_harnesses
  run agents_config_harnesses::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- preflight ---

@test "preflight passes for known harnesses" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  run agents_config_harnesses::preflight
  [ "$status" -eq 0 ]
}

@test "preflight fails on an unknown harness, even after a valid one" {
  STUB_OUTPUT=$'foo\nbogus' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_is_available "bogus"
  mktest::stub_function agents_config_harnesses::_available
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_harnesses::preflight
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

@test "preflight dispatches each harness's own preflight when it defines one" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  mktest::stub_function agents_config_harnesses::foo::preflight
  mktest::stub_function agents_config_harnesses::bar::preflight
  agents_config_harnesses::preflight
  mktest::assert_stub_called agents_config_harnesses::foo::preflight
  mktest::assert_stub_called agents_config_harnesses::bar::preflight
}

@test "preflight returns success when a known harness has no preflight" {
  # Neither fake harness defines a preflight → the loop's last command (the
  # failing declare -F) must not become the return value (the `return 0` pin).
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  run agents_config_harnesses::preflight
  [ "$status" -eq 0 ]
}

# --- install ---

@test "install in dry-run reports and projects nothing" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_harnesses::_agents_dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project
  mktest::stub_function agents_config_harnesses::bar::project
  agents_config_harnesses::install
  mktest::assert_stub_not_called agents_config_harnesses::foo::project
  mktest::assert_stub_not_called agents_config_harnesses::bar::project
  mktest::assert_stub_called logging::dry_run
}

@test "install projects each harness that isn't already projected" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_harnesses::_agents_dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project "/agents"
  mktest::stub_function agents_config_harnesses::bar::project "/agents"
  agents_config_harnesses::install
  mktest::assert_stub_called agents_config_harnesses::foo::project "/agents"
  mktest::assert_stub_called agents_config_harnesses::bar::project "/agents"
}

@test "install skips harnesses already projected" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_harnesses::_agents_dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project
  mktest::stub_function agents_config_harnesses::bar::project
  agents_config_harnesses::install
  mktest::assert_stub_not_called agents_config_harnesses::foo::project
  mktest::assert_stub_not_called agents_config_harnesses::bar::project
}

@test "install is a clean no-op when no harnesses are configured" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_harnesses::_agents_dir
  mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  run agents_config_harnesses::install
  [ "$status" -eq 0 ]
}

# --- _available / _is_available (these legitimately inspect the real sourced submodule) ---

@test "_is_available is true for a sourced harness submodule" {
  agents_config_harnesses::_is_available claude_code
}

@test "_is_available is false for an unknown harness" {
  run ! agents_config_harnesses::_is_available bogus
}

@test "_available lists harnesses whose submodule defines project" {
  run agents_config_harnesses::_available
  [[ "$output" == *claude_code* ]]
}

# --- _harnesses / _agents_dir ---

@test "_harnesses reads the configured harnesses list" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function config::get_array "module.agents_config_harnesses.harnesses"
  run agents_config_harnesses::_harnesses
  [ "${lines[0]}" = "foo" ]
  [ "${lines[1]}" = "bar" ]
}

@test "_harnesses is empty (success) when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array "module.agents_config_harnesses.harnesses"
  run agents_config_harnesses::_harnesses
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_agents_dir reads the setup module's dir key with the xdg default" {
  STUB_OUTPUT="/custom/agents" mktest::stub_function config::get "module.agents_config_setup.dir" "--default" "$HOME/.config/agents"
  run agents_config_harnesses::_agents_dir
  [ "$output" = "/custom/agents" ]
}
