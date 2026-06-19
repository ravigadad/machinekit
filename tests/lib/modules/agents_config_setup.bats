#!/usr/bin/env bats
# Tests for lib/modules/agents_config_setup.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/agents_config_setup.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_setup.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
  mktest::stub_function logging::dry_run
}

# --- preflight ---

@test "preflight passes when the dir is already present" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  mktest::stub_function agents_config_setup::_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_source
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_setup::preflight
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight passes when the dir is absent but a valid source is configured" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_OUTPUT="https://github.com/user/agents" mktest::stub_function agents_config_setup::_source
  STUB_OUTPUT="" mktest::stub_function agents_config_setup::_source_protocol
  mktest::stub_function fetch::resolve_protocol "https://github.com/user/agents" ""
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_setup::preflight
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight fails when the source and protocol override are incompatible" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_OUTPUT="https://github.com/user/agents" mktest::stub_function agents_config_setup::_source
  STUB_OUTPUT="cp" mktest::stub_function agents_config_setup::_source_protocol
  STUB_EXIT=1 mktest::stub_function fetch::resolve_protocol "https://github.com/user/agents" "cp"
  run agents_config_setup::preflight
  [ "$status" -ne 0 ]
  mktest::assert_stub_called fetch::resolve_protocol "https://github.com/user/agents" "cp"
}

@test "preflight fails when the dir is absent and no source is configured" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_source
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_setup::preflight
  [ "$status" -ne 0 ]
  MATCH="source" mktest::assert_stub_called lifecycle::fail
}

# --- install ---

@test "install skips a present dir in a normal run and fetches nothing" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  mktest::stub_function agents_config_setup::_present "/agents"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function fetch::resolve_protocol
  mktest::stub_function fetch::into
  agents_config_setup::install
  mktest::assert_stub_not_called fetch::into
  mktest::assert_stub_not_called fetch::resolve_protocol
}

@test "install over a present dir in dry-run reports the no-op and fetches nothing" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  mktest::stub_function agents_config_setup::_present "/agents"
  mktest::stub_function input::is_dry_run
  mktest::stub_function fetch::resolve_protocol
  mktest::stub_function fetch::into
  agents_config_setup::install
  mktest::assert_stub_not_called fetch::into
  mktest::assert_stub_called logging::dry_run
}

@test "install seeds the dir from the source when absent" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_OUTPUT="https://github.com/user/agents" mktest::stub_function agents_config_setup::_source
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="" mktest::stub_function agents_config_setup::_source_protocol
  STUB_OUTPUT="git" mktest::stub_function fetch::resolve_protocol "https://github.com/user/agents" ""
  mktest::stub_function fetch::into "https://github.com/user/agents" "/agents" "git"
  agents_config_setup::install
  mktest::assert_stub_called fetch::into "https://github.com/user/agents" "/agents" "git"
}

@test "install passes a configured protocol override through to resolve_protocol" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_OUTPUT="/local/agents" mktest::stub_function agents_config_setup::_source
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="cp" mktest::stub_function agents_config_setup::_source_protocol
  STUB_OUTPUT="cp" mktest::stub_function fetch::resolve_protocol "/local/agents" "cp"
  mktest::stub_function fetch::into "/local/agents" "/agents" "cp"
  agents_config_setup::install
  mktest::assert_stub_called fetch::into "/local/agents" "/agents" "cp"
}

@test "install in dry-run reports intent and does not fetch" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_RETURN=1 mktest::stub_function agents_config_setup::_present "/agents"
  STUB_OUTPUT="https://github.com/user/agents" mktest::stub_function agents_config_setup::_source
  mktest::stub_function input::is_dry_run
  mktest::stub_function fetch::resolve_protocol
  mktest::stub_function fetch::into
  agents_config_setup::install
  mktest::assert_stub_not_called fetch::into
  mktest::assert_stub_not_called fetch::resolve_protocol
  mktest::assert_stub_called logging::dry_run
}

# --- config accessors (dir, _source, _source_protocol) ---

@test "dir reads the dir key with the xdg default" {
  STUB_OUTPUT="/custom/agents" mktest::stub_function config::get "module.agents_config_setup.dir" "--default" "$HOME/.config/agents"
  run agents_config_setup::dir
  [ "$output" = "/custom/agents" ]
}

@test "_source reads the source key, defaulting to empty" {
  STUB_OUTPUT="https://github.com/user/agents" mktest::stub_function config::get "module.agents_config_setup.source" "--default" ""
  run agents_config_setup::_source
  [ "$output" = "https://github.com/user/agents" ]
}

@test "_source_protocol reads the source_protocol key, defaulting to empty" {
  STUB_OUTPUT="cp" mktest::stub_function config::get "module.agents_config_setup.source_protocol" "--default" ""
  run agents_config_setup::_source_protocol
  [ "$output" = "cp" ]
}

# --- _present ---

@test "_present is true for an existing non-empty dir" {
  local dir="$BATS_TEST_TMPDIR/agents"
  mkdir "$dir"
  printf 'x' > "$dir/AGENTS.md"
  agents_config_setup::_present "$dir"
}

@test "_present is false for an absent dir" {
  run ! agents_config_setup::_present "$BATS_TEST_TMPDIR/nope"
}

@test "_present is false for an existing empty dir" {
  local dir="$BATS_TEST_TMPDIR/empty"
  mkdir "$dir"
  run ! agents_config_setup::_present "$dir"
}
