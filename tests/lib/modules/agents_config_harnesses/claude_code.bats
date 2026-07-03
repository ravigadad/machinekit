#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses/claude_code.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/agents_config_harnesses/claude_code.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses/claude_code.sh"
}

# --- requires ---

@test "requires declares the claude_code dependency" {
  run agents_config_harnesses::claude_code::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude_code" ]
}

# --- projection_present ---

@test "projection_present is true when both bindings are present" {
  mktest::stub_function agents_config_harnesses::claude_code::_skills_link_present "/agents"
  mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
  agents_config_harnesses::claude_code::projection_present "/agents"
}

@test "projection_present is false when the skills link is missing" {
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::claude_code::_skills_link_present "/agents"
  mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
  run ! agents_config_harnesses::claude_code::projection_present "/agents"
}

@test "projection_present is false when the AGENTS.md import is missing" {
  mktest::stub_function agents_config_harnesses::claude_code::_skills_link_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
  run ! agents_config_harnesses::claude_code::projection_present "/agents"
}

# --- project ---

@test "project ensures both the skills link and the AGENTS.md import" {
  mktest::stub_function agents_config_harnesses::claude_code::_ensure_skills_link
  mktest::stub_function agents_config_harnesses::claude_code::_ensure_agents_md_import
  agents_config_harnesses::claude_code::project "/agents"
  mktest::assert_stub_called agents_config_harnesses::claude_code::_ensure_skills_link "/agents"
  mktest::assert_stub_called agents_config_harnesses::claude_code::_ensure_agents_md_import "/agents"
}

# --- _ensure_skills_link ---

@test "_ensure_skills_link delegates to _ensure_link with the skills link and dir paths" {
  STUB_OUTPUT="/home/.claude/skills" mktest::stub_function agents_config_harnesses::claude_code::_skills_link_path
  STUB_OUTPUT="/agents/skills" mktest::stub_function agents_config_harnesses::claude_code::_skills_dir "/agents"
  mktest::stub_function agents_config_harnesses::_ensure_link "/home/.claude/skills" "/agents/skills"
  agents_config_harnesses::claude_code::_ensure_skills_link "/agents"
  mktest::assert_stub_called agents_config_harnesses::_ensure_link "/home/.claude/skills" "/agents/skills"
}

# --- _ensure_agents_md_import ---

@test "_ensure_agents_md_import creates CLAUDE.md with the import when the file is absent" {
  local home_dir; home_dir="$(mktemp -d)"
  local claude_md_path="$home_dir/.claude/CLAUDE.md"
  STUB_OUTPUT="$claude_md_path" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  STUB_OUTPUT="@the-import-line" mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_line "/agents"
  agents_config_harnesses::claude_code::_ensure_agents_md_import "/agents"
  [ -f "$claude_md_path" ]
  grep -qF "@the-import-line" "$claude_md_path"
}

@test "_ensure_agents_md_import appends the import when the line is absent, preserving content" {
  local home_dir; home_dir="$(mktemp -d)"
  local claude_md_path="$home_dir/.claude/CLAUDE.md"
  mkdir -p "$home_dir/.claude"
  printf '# existing content\n' > "$claude_md_path"
  STUB_OUTPUT="$claude_md_path" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  STUB_OUTPUT="@the-import-line" mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_line "/agents"
  agents_config_harnesses::claude_code::_ensure_agents_md_import "/agents"
  grep -qF "# existing content" "$claude_md_path"
  grep -qF "@the-import-line" "$claude_md_path"
}

@test "_ensure_agents_md_import is a no-op (no duplicate) when the import is already present" {
  local home_dir; home_dir="$(mktemp -d)"
  local claude_md_path="$home_dir/.claude/CLAUDE.md"
  mkdir -p "$home_dir/.claude"
  printf '@the-import-line\n' > "$claude_md_path"
  STUB_OUTPUT="@the-import-line" mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_line "/agents"
  STUB_OUTPUT="$claude_md_path" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  agents_config_harnesses::claude_code::_ensure_agents_md_import "/agents"
  [ "$(grep -cF "@the-import-line" "$claude_md_path")" -eq 1 ]
}

# --- _skills_link_present ---

@test "_skills_link_present delegates to _link_present with the skills link and dir paths" {
  STUB_OUTPUT="/home/.claude/skills" mktest::stub_function agents_config_harnesses::claude_code::_skills_link_path
  STUB_OUTPUT="/agents/skills" mktest::stub_function agents_config_harnesses::claude_code::_skills_dir "/agents"
  mktest::stub_function agents_config_harnesses::_link_present "/home/.claude/skills" "/agents/skills"
  agents_config_harnesses::claude_code::_skills_link_present "/agents"
  mktest::assert_stub_called agents_config_harnesses::_link_present "/home/.claude/skills" "/agents/skills"
}

# --- _agents_md_import_present ---

@test "_agents_md_import_present is true when the import line is in CLAUDE.md" {
  local claude_md_path; claude_md_path="$(mktemp)"
  printf 'stuff\n@the-import-line\nmore\n' > "$claude_md_path"
  STUB_OUTPUT="$claude_md_path" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  STUB_OUTPUT="@the-import-line" mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_line "/agents"
  agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
}

@test "_agents_md_import_present is false when CLAUDE.md is absent" {
  STUB_OUTPUT="/nonexistent/CLAUDE.md" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  run ! agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
}

@test "_agents_md_import_present is false when the import line is missing" {
  local claude_md_path; claude_md_path="$(mktemp)"
  printf 'unrelated content\n' > "$claude_md_path"
  STUB_OUTPUT="$claude_md_path" mktest::stub_function agents_config_harnesses::claude_code::_claude_md_path
  STUB_OUTPUT="@the-import-line" mktest::stub_function agents_config_harnesses::claude_code::_agents_md_import_line "/agents"
  run ! agents_config_harnesses::claude_code::_agents_md_import_present "/agents"
}

# --- path / value helpers ---

@test "_skills_link_path points at ~/.claude/skills" {
  run agents_config_harnesses::claude_code::_skills_link_path
  [ "$output" = "$HOME/.claude/skills" ]
}

@test "_claude_md_path points at the global ~/.claude/CLAUDE.md" {
  run agents_config_harnesses::claude_code::_claude_md_path
  [ "$output" = "$HOME/.claude/CLAUDE.md" ]
}

@test "_skills_dir is the skills subdir of the agents config dir" {
  run agents_config_harnesses::claude_code::_skills_dir "/x/agents"
  [ "$output" = "/x/agents/skills" ]
}

@test "_agents_md_import_line is an @import of AGENTS.md" {
  run agents_config_harnesses::claude_code::_agents_md_import_line "/x/agents"
  [ "$output" = "@/x/agents/AGENTS.md" ]
}
