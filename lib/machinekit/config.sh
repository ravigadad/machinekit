#!/usr/bin/env bash
# Blueprint config loader — parses and merges machinekit.toml files.
#
# common/machinekit.toml is the base; machine_types/<type>/machinekit.toml
# is merged on top, with type values winning on key conflict.
[ -n "${_MK_CONFIG_LOADED:-}" ] && return 0
_MK_CONFIG_LOADED=1

config::load() {
  local blueprints_dir common_json type_json merged
  blueprints_dir=$(blueprints::dir)

  common_json=$(config::_common_json "$blueprints_dir")
  type_json=$(config::_type_json "$blueprints_dir")

  merged=$(config::_merge_json "$common_json" "$type_json")

  context::set "config" "$merged" --json
  logging::debug "config: loaded"
}

config::get() {
  local key="$1"; shift
  context::get "config${key:+.$key}" "$@"
}

config::get_array() {
  context::get_array "config${1:+.$1}"
}

# config::get_json KEY [DEFAULT] — the config subtree at dotted KEY as compact
# JSON, or DEFAULT (default "null") when KEY is unset. The object/array
# counterpart to config::get (scalars), so a reader wanting a subtree doesn't
# reach past config:: into the store's layout. Type-preserving: a scalar comes
# back as valid JSON (a quoted string, a number), never a bare word — so callers
# can validate the shape rather than choke on a misconfigured value.
config::get_json() {
  local key="$1" default="${2:-null}" val
  if val="$(context::get_json "config${key:+.$key}")"; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$default"
  fi
}

# config::entries KEY [KEY_FIELD] — the enabled entries of the keyed collection at
# KEY, as a compact JSON array, or nothing at all when none are enabled (so an
# empty-string check still means "no entries"). An entry is off when it sets
# `enabled = false`; `enabled` is stripped from what's emitted.
# With KEY_FIELD, each entry's key fills that field unless the entry sets it itself,
# so `[module.x.databases.hindsight]` alone means a database named hindsight; two
# enabled entries that end up with the same value there are an error.
# Shape errors are fatal, so call it as a plain `var=$(…)` assignment at least once
# (in preflight): inside `< <(…)` or `local var=$(…)` the failure would not stop
# the run.
config::entries() {
  local key="$1" key_field="${2:-}" collection
  collection=$(config::get_json "$key" "{}")
  config::entries_from_json "$collection" "$key" "$key_field"
}

# config::entries_from_json JSON LABEL [KEY_FIELD] — config::entries for a
# collection already in hand, such as one nested inside another entry. LABEL names
# the collection in errors.
config::entries_from_json() {
  local collection="$1" label="$2" key_field="${3:-}" shape_error entries
  shape_error=$(config::_collection_shape_error "$collection")
  config::_fail_on_shape_error "$label" "$shape_error"
  entries=$(config::_enabled_entries "$collection" "$key_field")
  if [ -n "$key_field" ]; then
    shape_error=$(config::_duplicate_field_error "$entries" "$key_field")
    config::_fail_on_shape_error "$label" "$shape_error"
  fi
  [ -z "$entries" ] || printf '%s\n' "$entries"
}

# config::enabled_table KEY — the keyed collection at KEY as a table of its enabled
# entries, each still under its own key and with `enabled` stripped ({} when none).
# For a module that needs the key itself (a bank name in a URL, say) and sends each
# entry on verbatim, where config::entries' added field would travel with it.
config::enabled_table() {
  local key="$1" collection shape_error
  collection=$(config::get_json "$key" "{}")
  shape_error=$(config::_collection_shape_error "$collection")
  config::_fail_on_shape_error "$key" "$shape_error"
  config::_enabled_table "$collection"
}

# config::extended_list ENTRY_JSON LIST_NAME before|after LABEL — the entry's
# LIST_NAME list combined with its additional_LIST_NAME list, as a compact JSON
# array. A machine type sets additional_LIST_NAME to add to a list it inherits,
# since the config merge replaces lists whole. The caller places the additions
# because only it knows what order means for that list: Syncthing ignore patterns
# use the first match, .gitignore the last. LABEL names the entry in errors; call
# it as a plain `var=$(…)` assignment for a malformed list to stop the run.
config::extended_list() {
  local entry="$1" list_name="$2" position="$3" label="$4" shape_error
  shape_error=$(config::_list_shape_error "$entry" "$list_name")
  config::_fail_on_shape_error "$label" "$shape_error"
  config::_combined_list "$entry" "$list_name" "$position"
}

config::_fail_on_shape_error() {
  local label="$1" shape_error="$2"
  [ -z "$shape_error" ] || lifecycle::fail "config: $label: $shape_error"
}

config::_list_shape_error() {
  printf '%s' "$1" | jq -r --arg list_name "$2" '
    first(($list_name, "additional_\($list_name)") as $name
      | select(has($name) and ((.[$name] | type) != "array"))
      | "\($name) must be a list")
    // empty'
}

config::_combined_list() {
  printf '%s' "$1" | jq -c --arg list_name "$2" --arg position "$3" '
    (.[$list_name] // []) as $inherited
    | (.["additional_\($list_name)"] // []) as $additional
    | if $position == "before" then $additional + $inherited
      elif $position == "after" then $inherited + $additional
      else error("unknown position: \($position)") end'
}

# Keys are held to TOML's bare-key characters because config::get addresses
# entries by dotted path, so a key containing a dot could never be read on its own.
config::_collection_shape_error() {
  printf '%s' "$1" | jq -r '
    if type != "object" then
      "must be a table of entries, each under its own key"
    else
      first(to_entries[]
        | if (.value | type) != "object" then
            "entry \(.key | tojson) must be a table (to turn it off, write { enabled = false })"
          elif (.key | test("^[A-Za-z0-9_-]+$") | not) then
            "entry key \(.key | tojson) must use only letters, digits, underscores and hyphens"
          elif (.value | has("enabled")) and ((.value.enabled | type) != "boolean") then
            "entry \(.key | tojson) has a non-boolean enabled"
          else empty end)
      // empty
    end'
}

config::_enabled_entries() {
  config::_enabled_table "$1" | jq -c --arg key_field "$2" '
    [to_entries[]
      | (if $key_field == "" then {} else {($key_field): .key} end) + .value]
    | if length == 0 then empty else . end'
}

# An empty or missing value is left to the module's own check, which can say what
# the field is for.
config::_duplicate_field_error() {
  printf '%s' "$1" | jq -r --arg field "$2" '
    [.[][$field] | select(. != null and . != "")]
    | group_by(.) | map(select(length > 1)) | first // empty
    | "two entries set \($field) to \(.[0] | tojson)"'
}

config::_enabled_table() {
  printf '%s' "$1" | jq -c 'with_entries(select(.value.enabled != false) | .value |= del(.enabled))'
}

config::_common_json() {
  local blueprints_dir="$1"
  config::_parse_toml "$blueprints_dir/common/machinekit.toml"
}

config::_type_json() {
  local blueprints_dir="$1" machine_type
  machine_type=$(context::get "machine_type" 2>/dev/null || true)
  [ -n "$machine_type" ] || { printf '{}'; return 0; }
  config::_parse_toml "$blueprints_dir/machine_types/$machine_type/machinekit.toml"
}

# A list of tables is rejected per file, before the merge: jq's `*` lets one
# layer's list silently replace the other layer's keyed table (or the reverse),
# so a blueprint mixing the two forms would lose entries with no error.
config::_parse_toml() {
  local path="$1" parsed table_list_path
  [ -f "$path" ] || { printf '{}'; return 0; }
  parsed=$(toml2json "$path")
  table_list_path=$(config::_first_table_list_path "$parsed")
  [ -z "$table_list_path" ] || lifecycle::fail \
    "config: $path: $table_list_path is a list of tables. machinekit reads every collection as a table keyed by an identifier — write each entry as [$table_list_path.<identifier>] instead."
  printf '%s\n' "$parsed"
}

# The dotted key of the first list holding a table, at any depth, or nothing.
# Catches both [[x]] and the inline x = [{ … }], which parse identically.
config::_first_table_list_path() {
  printf '%s' "$1" | jq -r '
    first(paths(type == "array" and any(.[]; type == "object")))
    | map(tostring) | join(".")'
}

config::_merge_json() {
  printf '%s\n' "$@" | jq -s 'reduce .[] as $o ({}; . * $o)'
}
