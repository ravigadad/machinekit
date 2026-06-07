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

# --- tool_version_manager::default_satisfier ---

@test "default_satisfier outputs mise" {
  result=$(tool_version_manager::default_satisfier)
  [ "$result" = "mise" ]
}

# --- tool_version_manager::requires ---

@test "requires outputs the default satisfier" {
  result=$(tool_version_manager::requires)
  [ "$result" = "mise" ]
}

# --- tool_version_manager::install ---

@test "install is a no-op" {
  run tool_version_manager::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
