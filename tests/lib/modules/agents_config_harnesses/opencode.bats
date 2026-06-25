#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses/opencode.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/agents_config_harnesses/opencode.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses/opencode.sh"
}

# --- requires ---

@test "requires declares the opencode install dependency" {
  run agents_config_harnesses::opencode::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "opencode" ]
}

# --- _agents_md_link_path ---

@test "_agents_md_link_path is opencode's global AGENTS.md under HOME" {
  HOME=/fake/home
  run agents_config_harnesses::opencode::_agents_md_link_path
  [ "$output" = "/fake/home/.config/opencode/AGENTS.md" ]
}

# --- project ---

@test "project ensures the AGENTS.md symlink at opencode's path" {
  STUB_OUTPUT="/home/.config/opencode/AGENTS.md" mktest::stub_function agents_config_harnesses::opencode::_agents_md_link_path
  mktest::stub_function agents_config_harnesses::_ensure_agents_md_link "/home/.config/opencode/AGENTS.md" "/agents"
  agents_config_harnesses::opencode::project "/agents"
  mktest::assert_stub_called agents_config_harnesses::_ensure_agents_md_link "/home/.config/opencode/AGENTS.md" "/agents"
}

# --- projection_present ---

@test "projection_present delegates to the shared link check at opencode's path" {
  STUB_OUTPUT="/home/.config/opencode/AGENTS.md" mktest::stub_function agents_config_harnesses::opencode::_agents_md_link_path
  mktest::stub_function agents_config_harnesses::_agents_md_link_present "/home/.config/opencode/AGENTS.md" "/agents"
  agents_config_harnesses::opencode::projection_present "/agents"
  mktest::assert_stub_called agents_config_harnesses::_agents_md_link_present "/home/.config/opencode/AGENTS.md" "/agents"
}
