#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses/hermes.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/agents_config_harnesses/hermes.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses/hermes.sh"
}

# --- requires ---

@test "requires declares the hermes install dependency" {
  run agents_config_harnesses::hermes::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "hermes" ]
}

# --- project ---

@test "project links SOUL.md into the hermes dir when it is authored" {
  local config_dir; config_dir="$(mktemp -d)"; printf 'x\n' > "$config_dir/SOUL.md"
  STUB_OUTPUT="/home/.hermes/SOUL.md" mktest::stub_function agents_config_harnesses::hermes::_soul_link_path
  mktest::stub_function agents_config_harnesses::_ensure_link "/home/.hermes/SOUL.md" "$config_dir/SOUL.md"
  agents_config_harnesses::hermes::project "$config_dir"
  mktest::assert_stub_called agents_config_harnesses::_ensure_link "/home/.hermes/SOUL.md" "$config_dir/SOUL.md"
}

@test "project is a no-op when SOUL.md is not authored" {
  local config_dir; config_dir="$(mktemp -d)"
  mktest::stub_function agents_config_harnesses::hermes::_soul_link_path
  mktest::stub_function agents_config_harnesses::_ensure_link
  agents_config_harnesses::hermes::project "$config_dir"
  mktest::assert_stub_not_called agents_config_harnesses::_ensure_link
}

# --- projection_present ---

@test "projection_present is true (nothing to do) when SOUL.md is not authored" {
  local config_dir; config_dir="$(mktemp -d)"
  mktest::stub_function agents_config_harnesses::hermes::_soul_link_path
  agents_config_harnesses::hermes::projection_present "$config_dir"
}

@test "projection_present delegates to the shared link check when SOUL.md is authored" {
  local config_dir; config_dir="$(mktemp -d)"; printf 'x\n' > "$config_dir/SOUL.md"
  STUB_OUTPUT="/home/.hermes/SOUL.md" mktest::stub_function agents_config_harnesses::hermes::_soul_link_path
  mktest::stub_function agents_config_harnesses::_link_present "/home/.hermes/SOUL.md" "$config_dir/SOUL.md"
  agents_config_harnesses::hermes::projection_present "$config_dir"
  mktest::assert_stub_called agents_config_harnesses::_link_present "/home/.hermes/SOUL.md" "$config_dir/SOUL.md"
}

# --- _soul_link_path ---

@test "_soul_link_path is SOUL.md under the hermes home" {
  HOME=/fake/home
  run agents_config_harnesses::hermes::_soul_link_path
  [ "$output" = "/fake/home/.hermes/SOUL.md" ]
}

# --- _soul_source ---

@test "_soul_source is SOUL.md within the agents config dir" {
  run agents_config_harnesses::hermes::_soul_source /agents
  [ "$output" = "/agents/SOUL.md" ]
}
