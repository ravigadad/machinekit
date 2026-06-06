#!/usr/bin/env bats
# Tests for lib/machinekit/config.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/config.sh
  source "$MACHINEKIT_DIR/lib/machinekit/config.sh"
  unset _MK_CONFIG_LOADED

  mktest::stub_function logging::debug

  FAKE_BP="$BATS_TEST_TMPDIR/blueprints"
  mkdir -p "$FAKE_BP/common"
  STUB_OUTPUT="$FAKE_BP" mktest::stub_function blueprints::dir
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  config::load() { echo "original"; }
  _MK_CONFIG_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/config.sh"
  [ "$(config::load)" = "original" ]
}

# --- config::load ---

@test "load merges type TOML on top of common when machine_type is set" {
  STUB_OUTPUT="the-common-json" mktest::stub_function config::_common_json "$FAKE_BP"
  STUB_OUTPUT="the-type-json" mktest::stub_function config::_type_json "$FAKE_BP"
  STUB_OUTPUT="the-merged-json" mktest::stub_function config::_merge_json "the-common-json" "the-type-json"
  mktest::stub_function context::set "config" "the-merged-json" --json
  config::load
  mktest::assert_stub_called context::set "config" "the-merged-json" --json
}

# --- config::get ---

@test "get retrieves given key from context's config" {
  STUB_OUTPUT="the-value" mktest::stub_function context::get "config.something"
  result=$(config::get "something")
  [ "$result" = "the-value" ]
}

@test "get forwards extra flags to context::get" {
  STUB_OUTPUT="the-value" mktest::stub_function context::get "config.something" --required --default "fallback" --prompt "Enter it"
  result=$(config::get "something" --required --default "fallback" --prompt "Enter it")
  [ "$result" = "the-value" ]
}

@test "get retrieves entire config object when called with no argument" {
  STUB_OUTPUT="the-config" mktest::stub_function context::get "config"
  result=$(config::get)
  [ "$result" = "the-config" ]
}

# --- config::get_array ---

@test "get_array retrieves array at given key from context's config" {
  mktest::stub_function context::get_array "config.modules"
  config::get_array "modules"
  mktest::assert_stub_called context::get_array "config.modules"
}

# --- config::_common_json ---

@test "_common_json returns parsed machinekit toml file in common dir" {
  STUB_OUTPUT="the-json" mktest::stub_function config::_parse_toml "$FAKE_BP/common/machinekit.toml"
  result=$(config::_common_json "$FAKE_BP")
  [ "$result" = "the-json" ]
}

# --- config::_type_json ---

@test "_type_json returns parsed machinekit toml file in type-specific dir" {
  STUB_OUTPUT="the-machine-type" mktest::stub_function context::get "machine_type"
  STUB_OUTPUT="the-json" mktest::stub_function config::_parse_toml "$FAKE_BP/machine_types/the-machine-type/machinekit.toml"
  result=$(config::_type_json "$FAKE_BP")
  [ "$result" = "the-json" ]
}

@test "_type_json returns empty JSON if no machine type" {
  STUB_OUTPUT="" mktest::stub_function context::get "machine_type"
  result=$(config::_type_json "$FAKE_BP")
  [ "$result" = "{}" ]
}

# --- config::_parse_toml ---

@test "_parse_toml returns an empty object for a missing file" {
  result=$(config::_parse_toml "$FAKE_BP/nonexistent.toml")
  [ "$result" = "{}" ]
}

@test "_parse_toml parses a valid TOML file into JSON" {
  printf 'answer = 42\n' > "$FAKE_BP/test.toml"
  result=$(config::_parse_toml "$FAKE_BP/test.toml")
  [ "$(printf '%s' "$result" | jq -r '.answer')" = "42" ]
}

# --- config::_merge_json ---

@test "_merge_json returns a merged object with the given JSON args" {
  result=$(config::_merge_json '{ "a": 3, "b": 5 }' '{ "b": 4 }' '{ "c": 2 }')
  expected=$(jq -n '{ "a": 3, "b": 4, "c": 2 }')
  [ "$result" = "$expected" ]
}

@test "_merge_json works with empty JSON args" {
  result=$(config::_merge_json '{ "a": 3, "b": 5 }' '{}')
  expected=$(jq -n '{ "a": 3, "b": 5 }')
  [ "$result" = "$expected" ]
}
