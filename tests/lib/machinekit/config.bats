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

# --- config::get_json ---

@test "get_json returns the subtree at the config-prefixed key as JSON" {
  STUB_OUTPUT='{"b":1}' mktest::stub_function context::get_json "config.module.x"
  run config::get_json "module.x"
  [ "$output" = '{"b":1}' ]
}

@test "get_json returns the given default when the key is unset" {
  STUB_RETURN=1 mktest::stub_function context::get_json "config.module.x"
  run config::get_json "module.x" "{}"
  [ "$output" = "{}" ]
}

@test "get_json defaults to null when no default is given and the key is unset" {
  STUB_RETURN=1 mktest::stub_function context::get_json "config.module.x"
  run config::get_json "module.x"
  [ "$output" = "null" ]
}

# --- config::entries ---

@test "entries reads the collection at the config key and returns its entries" {
  STUB_OUTPUT='{"fake":{}}' mktest::stub_function config::get_json "module.fake.entries" "{}"
  STUB_OUTPUT="the-entries" mktest::stub_function config::entries_from_json '{"fake":{}}' "module.fake.entries" "name"
  run config::entries "module.fake.entries" "name"
  [ "$output" = "the-entries" ]
}

@test "entries passes an empty key field when the caller names none" {
  STUB_OUTPUT='{"fake":{}}' mktest::stub_function config::get_json "module.fake.entries" "{}"
  STUB_OUTPUT="the-entries" mktest::stub_function config::entries_from_json '{"fake":{}}' "module.fake.entries" ""
  run config::entries "module.fake.entries"
  [ "$output" = "the-entries" ]
}

# --- config::entries_from_json ---

@test "entries_from_json returns the enabled entries when the collection is well-formed" {
  mktest::stub_function config::_collection_shape_error '{"fake":{}}'
  mktest::stub_function config::_fail_on_shape_error "module.fake.entries" ""
  STUB_OUTPUT="the-entries" mktest::stub_function config::_enabled_entries '{"fake":{}}' "name"
  mktest::stub_function config::_duplicate_field_error "the-entries" "name"
  run config::entries_from_json '{"fake":{}}' "module.fake.entries" "name"
  [ "$output" = "the-entries" ]
}

@test "entries_from_json fails naming the collection when its shape is wrong" {
  STUB_OUTPUT="the-shape-error" mktest::stub_function config::_collection_shape_error '{"fake":1}'
  STUB_EXIT=1 mktest::stub_function config::_fail_on_shape_error "module.fake.entries" "the-shape-error"
  mktest::stub_function config::_enabled_entries
  run config::entries_from_json '{"fake":1}' "module.fake.entries" ""
  [ "$status" -eq 1 ]
  mktest::assert_stub_called config::_fail_on_shape_error "module.fake.entries" "the-shape-error"
  mktest::assert_stub_not_called config::_enabled_entries
}

@test "entries_from_json fails naming the collection when two entries fill the key field with one value" {
  mktest::stub_function config::_collection_shape_error '{"fake":{}}'
  mktest::stub_function config::_fail_on_shape_error "module.fake.entries" ""
  STUB_OUTPUT="the-entries" mktest::stub_function config::_enabled_entries '{"fake":{}}' "name"
  STUB_OUTPUT="the-duplicate-error" mktest::stub_function config::_duplicate_field_error "the-entries" "name"
  STUB_EXIT=1 mktest::stub_function config::_fail_on_shape_error "module.fake.entries" "the-duplicate-error"
  run config::entries_from_json '{"fake":{}}' "module.fake.entries" "name"
  [ "$status" -eq 1 ]
  mktest::assert_stub_called config::_fail_on_shape_error "module.fake.entries" "the-duplicate-error"
}

@test "entries_from_json skips the duplicate check when no key field is named" {
  mktest::stub_function config::_collection_shape_error '{"fake":{}}'
  mktest::stub_function config::_fail_on_shape_error "module.fake.entries" ""
  STUB_OUTPUT="the-entries" mktest::stub_function config::_enabled_entries '{"fake":{}}' ""
  mktest::stub_function config::_duplicate_field_error
  run config::entries_from_json '{"fake":{}}' "module.fake.entries" ""
  [ "$output" = "the-entries" ]
  mktest::assert_stub_not_called config::_duplicate_field_error
}

# --- config::enabled_table ---

@test "enabled_table returns the collection's enabled entries as a table when it is well-formed" {
  STUB_OUTPUT='{"fake":{}}' mktest::stub_function config::get_json "module.fake.entries" "{}"
  mktest::stub_function config::_collection_shape_error '{"fake":{}}'
  mktest::stub_function config::_fail_on_shape_error "module.fake.entries" ""
  STUB_OUTPUT="the-table" mktest::stub_function config::_enabled_table '{"fake":{}}'
  run config::enabled_table "module.fake.entries"
  [ "$output" = "the-table" ]
}

@test "enabled_table fails naming the collection when its shape is wrong" {
  STUB_OUTPUT='{"fake":1}' mktest::stub_function config::get_json "module.fake.entries" "{}"
  STUB_OUTPUT="the-shape-error" mktest::stub_function config::_collection_shape_error '{"fake":1}'
  STUB_EXIT=1 mktest::stub_function config::_fail_on_shape_error "module.fake.entries" "the-shape-error"
  mktest::stub_function config::_enabled_table
  run config::enabled_table "module.fake.entries"
  [ "$status" -eq 1 ]
  mktest::assert_stub_called config::_fail_on_shape_error "module.fake.entries" "the-shape-error"
  mktest::assert_stub_not_called config::_enabled_table
}

# --- config::extended_list ---

@test "extended_list returns the combined list when both lists are well-formed" {
  mktest::stub_function config::_list_shape_error '{"fake":1}' "fake_list"
  mktest::stub_function config::_fail_on_shape_error "module.fake.entries.one" ""
  STUB_OUTPUT="the-list" mktest::stub_function config::_combined_list '{"fake":1}' "fake_list" "before"
  run config::extended_list '{"fake":1}' "fake_list" "before" "module.fake.entries.one"
  [ "$output" = "the-list" ]
}

@test "extended_list fails naming the entry when a list is malformed" {
  STUB_OUTPUT="the-shape-error" mktest::stub_function config::_list_shape_error '{"fake":1}' "fake_list"
  STUB_EXIT=1 mktest::stub_function config::_fail_on_shape_error "module.fake.entries.one" "the-shape-error"
  mktest::stub_function config::_combined_list
  run config::extended_list '{"fake":1}' "fake_list" "before" "module.fake.entries.one"
  [ "$status" -eq 1 ]
  mktest::assert_stub_called config::_fail_on_shape_error "module.fake.entries.one" "the-shape-error"
  mktest::assert_stub_not_called config::_combined_list
}

# --- config::_fail_on_shape_error ---

@test "_fail_on_shape_error fails with the label and the error" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail "config: module.fake.entries: the-shape-error"
  run config::_fail_on_shape_error "module.fake.entries" "the-shape-error"
  [ "$status" -eq 1 ]
  mktest::assert_stub_called lifecycle::fail "config: module.fake.entries: the-shape-error"
}

@test "_fail_on_shape_error does nothing when there is no error" {
  mktest::stub_function lifecycle::fail
  run config::_fail_on_shape_error "module.fake.entries" ""
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called lifecycle::fail
}

# --- config::_list_shape_error ---

@test "_list_shape_error reports nothing when both lists are lists or absent" {
  result=$(config::_list_shape_error '{"fake_list":["a"],"additional_fake_list":["b"]}' "fake_list")
  [ -z "$result" ]
  result=$(config::_list_shape_error '{}' "fake_list")
  [ -z "$result" ]
}

@test "_list_shape_error reports the list when it is not a list" {
  result=$(config::_list_shape_error '{"fake_list":"a"}' "fake_list")
  [[ "$result" == "fake_list "* ]]
}

@test "_list_shape_error reports the additional list when it is not a list" {
  result=$(config::_list_shape_error '{"additional_fake_list":"b"}' "fake_list")
  [[ "$result" == "additional_fake_list "* ]]
}

# --- config::_combined_list ---

@test "_combined_list puts the additional items before the inherited ones" {
  result=$(config::_combined_list '{"fake_list":["a1","a2"],"additional_fake_list":["b1"]}' "fake_list" "before")
  [ "$result" = '["b1","a1","a2"]' ]
}

@test "_combined_list puts the additional items after the inherited ones" {
  result=$(config::_combined_list '{"fake_list":["a1","a2"],"additional_fake_list":["b1"]}' "fake_list" "after")
  [ "$result" = '["a1","a2","b1"]' ]
}

@test "_combined_list fails on a position other than before or after" {
  run config::_combined_list '{}' "fake_list" "fake-position"
  [ "$status" -ne 0 ]
}

@test "_combined_list treats an absent list as empty" {
  result=$(config::_combined_list '{"additional_fake_list":["b1"]}' "fake_list" "after")
  [ "$result" = '["b1"]' ]
  result=$(config::_combined_list '{}' "fake_list" "after")
  [ "$result" = '[]' ]
}

# --- config::_collection_shape_error ---

@test "_collection_shape_error reports nothing for a well-formed collection" {
  result=$(config::_collection_shape_error '{"fake-one":{"enabled":false},"fake_two":{"a":1},"three":{}}')
  [ -z "$result" ]
}

@test "_collection_shape_error reports a collection that is not a table" {
  result=$(config::_collection_shape_error '["fake"]')
  [[ "$result" == *"table"* ]]
}

@test "_collection_shape_error reports an entry that is not a table, naming it" {
  result=$(config::_collection_shape_error '{"fake":false}')
  [[ "$result" == *"fake"*"table"* ]]
}

@test "_collection_shape_error reports a key outside the bare-key characters, naming it" {
  result=$(config::_collection_shape_error '{"fake.key":{}}')
  [[ "$result" == *"fake.key"*"letters"* ]]
}

@test "_collection_shape_error reports a non-boolean enabled, naming the entry" {
  result=$(config::_collection_shape_error '{"fake":{"enabled":"no"}}')
  [[ "$result" == *"fake"*"enabled"* ]]
}

# --- config::_enabled_entries ---

@test "_enabled_entries emits the enabled table's entries as a compact array" {
  STUB_OUTPUT='{"one":{"a":1},"three":{"b":2}}' mktest::stub_function config::_enabled_table '{"fake":"collection"}'
  run config::_enabled_entries '{"fake":"collection"}' ""
  [ "$output" = '[{"a":1},{"b":2}]' ]
}

@test "_enabled_entries fills the named field from the key" {
  STUB_OUTPUT='{"one":{"a":1}}' mktest::stub_function config::_enabled_table '{"fake":"collection"}'
  run config::_enabled_entries '{"fake":"collection"}' "name"
  [ "$output" = '[{"name":"one","a":1}]' ]
}

@test "_enabled_entries keeps an explicit value in the named field over the key" {
  STUB_OUTPUT='{"one":{"name":"explicit"}}' mktest::stub_function config::_enabled_table '{"fake":"collection"}'
  run config::_enabled_entries '{"fake":"collection"}' "name"
  [ "$output" = '[{"name":"explicit"}]' ]
}

@test "_enabled_entries emits nothing when no entry is enabled" {
  STUB_OUTPUT='{}' mktest::stub_function config::_enabled_table '{"fake":"collection"}'
  run config::_enabled_entries '{"fake":"collection"}' "name"
  [ -z "$output" ]
}

# --- config::_duplicate_field_error ---

@test "_duplicate_field_error reports nothing when every entry has its own value" {
  run config::_duplicate_field_error '[{"name":"one"},{"name":"two"}]' "name"
  [ -z "$output" ]
}

@test "_duplicate_field_error reports a value two entries share, naming the field" {
  run config::_duplicate_field_error '[{"name":"one"},{"name":"two"},{"name":"one"}]' "name"
  [ "$output" = 'two entries set name to "one"' ]
}

@test "_duplicate_field_error leaves empty and absent values to the module's own check" {
  run config::_duplicate_field_error '[{"name":""},{"name":""},{},{}]' "name"
  [ -z "$output" ]
}

@test "_duplicate_field_error reports nothing for no entries" {
  run config::_duplicate_field_error "" "name"
  [ -z "$output" ]
}

# --- config::_enabled_table ---

@test "_enabled_table keeps the enabled entries under their keys, stripping enabled" {
  run config::_enabled_table '{"one":{"a":1,"enabled":true},"two":{"enabled":false},"three":{"b":2}}'
  [ "$output" = '{"one":{"a":1},"three":{"b":2}}' ]
}

@test "_enabled_table is an empty table when every entry is disabled" {
  run config::_enabled_table '{"one":{"enabled":false}}'
  [ "$output" = '{}' ]
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
  mktest::stub_function config::_first_table_list_path '{"answer":42}'
  result=$(config::_parse_toml "$FAKE_BP/test.toml")
  [ "$(printf '%s' "$result" | jq -r '.answer')" = "42" ]
}

@test "_parse_toml fails naming the file and the key when the file holds a list of tables" {
  printf 'answer = 42\n' > "$FAKE_BP/test.toml"
  STUB_OUTPUT="module.fake.entries" mktest::stub_function config::_first_table_list_path '{"answer":42}'
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run config::_parse_toml "$FAKE_BP/test.toml"
  [ "$status" -eq 1 ]
  MATCH="test\.toml.*module\.fake\.entries" mktest::assert_stub_called lifecycle::fail
}

# --- config::_first_table_list_path ---

@test "_first_table_list_path returns the dotted key of a list of tables" {
  result=$(config::_first_table_list_path '{"module":{"fake":{"entries":[{"a":1}]}}}')
  [ "$result" = "module.fake.entries" ]
}

@test "_first_table_list_path returns nothing when no list holds a table" {
  result=$(config::_first_table_list_path '{"modules":["a","b"],"module":{"fake":{"entries":{"one":{"list":[1,2]}}}}}')
  [ -z "$result" ]
}

@test "_first_table_list_path finds a list of tables nested inside a keyed entry" {
  result=$(config::_first_table_list_path '{"module":{"fake":{"entries":{"one":{"nested":[{"a":1}]}}}}}')
  [ "$result" = "module.fake.entries.one.nested" ]
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
