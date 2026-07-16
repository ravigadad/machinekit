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

config::_parse_toml() {
  local path="$1"
  [ -f "$path" ] || { printf '{}'; return 0; }
  toml2json "$path"
}

config::_merge_json() {
  printf '%s\n' "$@" | jq -s 'reduce .[] as $o ({}; . * $o)'
}
