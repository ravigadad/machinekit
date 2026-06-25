#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses/codex.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/agents_config_harnesses/codex.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses/codex.sh"
}

# --- requires ---

@test "requires declares the codex install dependency" {
  run agents_config_harnesses::codex::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "codex" ]
}

# --- _agents_md_link_path ---

@test "_agents_md_link_path is Codex's global AGENTS.md under HOME" {
  HOME=/fake/home
  run agents_config_harnesses::codex::_agents_md_link_path
  [ "$output" = "/fake/home/.codex/AGENTS.md" ]
}

# --- project ---

@test "project ensures the AGENTS.md symlink at Codex's path" {
  STUB_OUTPUT="/home/.codex/AGENTS.md" mktest::stub_function agents_config_harnesses::codex::_agents_md_link_path
  mktest::stub_function agents_config_harnesses::_ensure_agents_md_link "/home/.codex/AGENTS.md" "/agents"
  agents_config_harnesses::codex::project "/agents"
  mktest::assert_stub_called agents_config_harnesses::_ensure_agents_md_link "/home/.codex/AGENTS.md" "/agents"
}

# --- projection_present ---

@test "projection_present delegates to the shared link check at Codex's path" {
  STUB_OUTPUT="/home/.codex/AGENTS.md" mktest::stub_function agents_config_harnesses::codex::_agents_md_link_path
  mktest::stub_function agents_config_harnesses::_agents_md_link_present "/home/.codex/AGENTS.md" "/agents"
  agents_config_harnesses::codex::projection_present "/agents"
  mktest::assert_stub_called agents_config_harnesses::_agents_md_link_present "/home/.codex/AGENTS.md" "/agents"
}
