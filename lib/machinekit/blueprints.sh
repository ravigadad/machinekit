#!/usr/bin/env bash
# Blueprint source resolution and fetch helpers.
#
# blueprints::fetch resolves the source address, sniffs the protocol, sets up
# the destination directory, and delegates to the appropriate fetch helper.
# Once fetch has run, blueprints::dir returns the destination directory.
#
# Source address: any URL or local path (context key: blueprints.source).
# Protocol: auto-sniffed from the source, overridable via blueprints.source_protocol.
#   URL                → git clone
#   path with .git/    → git clone (override to "cp" to copy instead)
#   path without .git/ → cp
[ -n "${_MK_BLUEPRINTS_LOADED:-}" ] && return 0
_MK_BLUEPRINTS_LOADED=1

# Permanent destination — exported so hooks can reference it.
export MACHINEKIT_BLUEPRINTS_DIR="$HOME/.local/share/machinekit/blueprints"

# Holds the active destination path during a fetch session (temp until finalized).
_MK_BLUEPRINTS_DIR=""

blueprints::fetch() {
  local source protocol
  source=$(context::get "blueprints.source" --required)
  protocol=$(blueprints::_resolve_protocol "$source")

  blueprints::_prepare_dest
  logging::step "Fetching blueprints ($protocol): $source"

  case "$protocol" in
    git) blueprints::_fetch_git "$source" ;;
    cp)  blueprints::_fetch_cp  "$source" ;;
  esac

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

blueprints::_resolve_protocol() {
  local source="$1"
  local protocol
  protocol=$(context::get "blueprints.source_protocol") || true

  if [ -z "$protocol" ]; then
    if blueprints::_is_url "$source" || [ -d "${source}/.git" ]; then
      protocol="git"
    else
      protocol="cp"
    fi
    context::set "blueprints.source_protocol" "$protocol"
  fi

  case "$protocol" in
    git) ;;
    cp)
      blueprints::_is_url "$source" && \
        lifecycle::fail "Protocol 'cp' is not compatible with a URL source: $source"
      ;;
    *)
      lifecycle::fail "Unknown blueprints protocol: $protocol (valid: git, cp)"
      ;;
  esac

  printf '%s\n' "$protocol"
}

blueprints::_prepare_dest() {
  _MK_BLUEPRINTS_DIR=$(mktemp -d)
  # git clone refuses a non-empty dir; drop the mktemp dir so clone/copy
  # creates it fresh.
  rmdir "$_MK_BLUEPRINTS_DIR"
  lifecycle::register_cleanup blueprints::cleanup_dest
}

blueprints::_fetch_git() {
  local source="$1" abs_source="$1"
  blueprints::_is_url "$source" || abs_source=$(blueprints::_resolve_source_path "$source")
  logging::info "Cloning $abs_source → $_MK_BLUEPRINTS_DIR"
  git clone -- "$abs_source" "$_MK_BLUEPRINTS_DIR"
}

blueprints::_fetch_cp() {
  local abs_source
  abs_source=$(blueprints::_resolve_source_path "$1")
  logging::info "Copying $abs_source → $_MK_BLUEPRINTS_DIR"
  mkdir -p "$_MK_BLUEPRINTS_DIR"
  cp -R -- "$abs_source/." "$_MK_BLUEPRINTS_DIR/"
}

# Looks-like-a-URL check for sources git clone accepts as remotes.
blueprints::_is_url() {
  case "$1" in
    http://*|https://*|ssh://*|git@*|file://*) return 0 ;;
    *) return 1 ;;
  esac
}

blueprints::_resolve_source_path() {
  local in="$1" abs
  [ -e "$in" ] || lifecycle::fail "Blueprint source path does not exist: $in"
  [ -d "$in" ] || lifecycle::fail "Blueprint source path is not a directory: $in"
  abs=$(cd "$in" && pwd) || lifecycle::fail "Could not resolve blueprint source path: $in"
  [ -n "$(ls -A "$abs")" ] || lifecycle::fail "Blueprint source path is empty: $in"
  printf '%s\n' "$abs"
}

blueprints::cleanup_dest() {
  [ -n "$_MK_BLUEPRINTS_DIR" ] || return 0
  rm -rf -- "$_MK_BLUEPRINTS_DIR"
  _MK_BLUEPRINTS_DIR=""
}
