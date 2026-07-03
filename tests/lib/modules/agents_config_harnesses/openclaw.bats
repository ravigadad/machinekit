#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses/openclaw.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/agents_config_harnesses/openclaw.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses/openclaw.sh"
}

# --- requires ---

@test "requires declares the openclaw install dependency" {
  run agents_config_harnesses::openclaw::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "openclaw" ]
}

# --- project ---

@test "project links entries whose source exists and skips those that don't" {
  local config_dir; config_dir="$(mktemp -d)"
  printf 'x\n' > "$config_dir/present.md"
  STUB_OUTPUT="/ws" mktest::stub_function agents_config_harnesses::openclaw::_workspace_dir
  STUB_OUTPUT=$'present.md\nabsent.md' mktest::stub_function agents_config_harnesses::openclaw::_projected_entries
  mktest::stub_function agents_config_harnesses::_ensure_link "/ws/present.md" "$config_dir/present.md"
  mktest::stub_function agents_config_harnesses::_ensure_link "/ws/absent.md" "$config_dir/absent.md"
  agents_config_harnesses::openclaw::project "$config_dir"
  mktest::assert_stub_called agents_config_harnesses::_ensure_link "/ws/present.md" "$config_dir/present.md"
  mktest::assert_stub_not_called agents_config_harnesses::_ensure_link "/ws/absent.md" "$config_dir/absent.md"
}

# --- projection_present ---

@test "projection_present is true (nothing to do) when the workspace is absent" {
  local missing; missing="$(mktemp -d)"; rmdir "$missing"
  STUB_OUTPUT="$missing" mktest::stub_function agents_config_harnesses::openclaw::_workspace_dir
  agents_config_harnesses::openclaw::projection_present /agents
}

@test "projection_present is true when every authored entry is linked" {
  local config_dir; config_dir="$(mktemp -d)"; printf 'x\n' > "$config_dir/present.md"
  local workspace; workspace="$(mktemp -d)"
  STUB_OUTPUT="$workspace" mktest::stub_function agents_config_harnesses::openclaw::_workspace_dir
  STUB_OUTPUT=$'present.md\nabsent.md' mktest::stub_function agents_config_harnesses::openclaw::_projected_entries
  mktest::stub_function agents_config_harnesses::_link_present "$workspace/present.md" "$config_dir/present.md"
  agents_config_harnesses::openclaw::projection_present "$config_dir"
  mktest::assert_stub_called agents_config_harnesses::_link_present "$workspace/present.md" "$config_dir/present.md"
  mktest::assert_stub_not_called agents_config_harnesses::_link_present "$workspace/absent.md" "$config_dir/absent.md"
}

@test "projection_present is false when an authored entry is not linked" {
  local config_dir; config_dir="$(mktemp -d)"; printf 'x\n' > "$config_dir/present.md"
  local workspace; workspace="$(mktemp -d)"
  STUB_OUTPUT="$workspace" mktest::stub_function agents_config_harnesses::openclaw::_workspace_dir
  STUB_OUTPUT="present.md" mktest::stub_function agents_config_harnesses::openclaw::_projected_entries
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_link_present "$workspace/present.md" "$config_dir/present.md"
  run ! agents_config_harnesses::openclaw::projection_present "$config_dir"
}

# --- _workspace_dir ---

@test "_workspace_dir is OpenClaw's default workspace under HOME" {
  HOME=/fake/home
  run agents_config_harnesses::openclaw::_workspace_dir
  [ "$output" = "/fake/home/.openclaw/workspace" ]
}

# --- _projected_entries ---

@test "_projected_entries are the identity files, AGENTS.md, and skills" {
  run agents_config_harnesses::openclaw::_projected_entries
  [ "${lines[0]}" = "SOUL.md" ]
  [ "${lines[1]}" = "IDENTITY.md" ]
  [ "${lines[2]}" = "USER.md" ]
  [ "${lines[3]}" = "AGENTS.md" ]
  [ "${lines[4]}" = "skills" ]
  [ "${#lines[@]}" -eq 5 ]
}
