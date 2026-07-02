#!/usr/bin/env bats
# Tests for lib/modules/capabilities/tool_version_manager.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/capabilities/tool_version_manager.sh
  source "$MACHINEKIT_DIR/lib/modules/capabilities/tool_version_manager.sh"
}

# --- tool_version_manager::is_capability ---

@test "is_capability returns 0" {
  tool_version_manager::is_capability
}

# --- tool_version_manager::exec ---

@test "exec runs the command through the version manager with the tool available" {
  mktest::stub_function input::command_exists mise
  mktest::stub_function mise "exec" "node@latest" "--" "fake_installer" "fake_arg"
  tool_version_manager::exec node@latest fake_installer fake_arg
  mktest::assert_stub_called mise "exec" "node@latest" "--" "fake_installer" "fake_arg"
}

@test "exec runs the command directly when no version manager is installed" {
  STUB_RETURN=1 mktest::stub_function input::command_exists mise
  mktest::stub_function mise
  mktest::stub_function fake_installer "fake_arg"
  tool_version_manager::exec node@latest fake_installer fake_arg
  mktest::assert_stub_called fake_installer "fake_arg"
  mktest::assert_stub_not_called mise
}

# --- tool_version_manager::default_satisfier ---

@test "default_satisfier outputs mise" {
  result=$(tool_version_manager::default_satisfier)
  [ "$result" = "mise" ]
}

# --- tool_version_manager::requires ---

@test "requires outputs the default_satisfier" {
  STUB_OUTPUT="some-satisfier" mktest::stub_function tool_version_manager::default_satisfier
  result=$(tool_version_manager::requires)
  [ "$result" = "some-satisfier" ]
}

# --- tool_version_manager::install ---

@test "install is a no-op" {
  run tool_version_manager::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
