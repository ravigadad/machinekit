#!/usr/bin/env bash
# Blueprint source resolution and fetch.
#
# blueprints::fetch resolves the source address (from context), prepares a temp
# destination, delegates the actual fetch to the source-agnostic fetch:: core,
# then atomically replaces the permanent location. blueprints::dir returns that
# location once fetch has run.
#
# Source address: any URL or local path (context key: blueprints.source).
# Protocol override: context key blueprints.source_protocol (else auto-sniffed by
# fetch::resolve_protocol). The protocol handling itself lives in fetch.sh.
[ -n "${_MK_BLUEPRINTS_LOADED:-}" ] && return 0
_MK_BLUEPRINTS_LOADED=1

# Permanent destination — exported so hooks can reference it.
export MACHINEKIT_BLUEPRINTS_DIR="$HOME/.local/share/machinekit/blueprints"

# Holds the active destination path during a fetch session (temp until finalized).
_MK_BLUEPRINTS_DIR=""

blueprints::fetch() {
  local source override protocol
  source=$(context::get "blueprints.source" --required)
  override=$(context::get "blueprints.source_protocol") || true
  protocol=$(fetch::resolve_protocol "$source" "$override")
  # Cache the sniffed protocol so the rest of the run sees a concrete value.
  [ -n "$override" ] || context::set "blueprints.source_protocol" "$protocol"

  blueprints::_prepare_dest
  logging::step "Fetching blueprints ($protocol): $source"
  fetch::into "$source" "$_MK_BLUEPRINTS_DIR" "$protocol"

  if ! input::is_dry_run; then
    mkdir -p "$(dirname "$MACHINEKIT_BLUEPRINTS_DIR")"
    rm -rf -- "$MACHINEKIT_BLUEPRINTS_DIR"
    mv "$_MK_BLUEPRINTS_DIR" "$MACHINEKIT_BLUEPRINTS_DIR"
    _MK_BLUEPRINTS_DIR="$MACHINEKIT_BLUEPRINTS_DIR"
  fi
}

blueprints::dir() {
  [ -n "$_MK_BLUEPRINTS_DIR" ] || lifecycle::fail "blueprints::dir called before blueprints::fetch"
  printf '%s\n' "$_MK_BLUEPRINTS_DIR"
}

blueprints::_prepare_dest() {
  _MK_BLUEPRINTS_DIR=$(mktemp -d)
  # git clone refuses a non-empty dir; drop the mktemp dir so clone/copy
  # creates it fresh.
  rmdir "$_MK_BLUEPRINTS_DIR"
  lifecycle::register_cleanup blueprints::cleanup_dest
}

blueprints::cleanup_dest() {
  [ -n "$_MK_BLUEPRINTS_DIR" ] || return 0
  rm -rf -- "$_MK_BLUEPRINTS_DIR"
  _MK_BLUEPRINTS_DIR=""
}
