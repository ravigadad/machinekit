#!/usr/bin/env bash
# Home staging — for preparing the "staging" area for file syncing.
[ -n "${_MK_HOME_STAGING_LOADED:-}" ] && return 0
_MK_HOME_STAGING_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../home.sh"

home::staging::dir() {
  [ -n "$_MK_HOME_STAGING_DIR" ] || \
    lifecycle::fail "home::staging::dir called before home::staging::build"
  printf '%s\n' "$_MK_HOME_STAGING_DIR"
}

home::staging::build() {
  home::staging::_prepare_dir
  logging::step "Building home staging dir"

  # Resolve once into a local: blueprints::dir can lifecycle::fail, and in
  # argument position that exit is swallowed by the command substitution. A
  # standalone assignment lets set -e propagate it (and it's a small DRY win).
  local blueprints_dir
  blueprints_dir="$(blueprints::dir)"

  local module
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    home::staging::_layer_dir "$(modules::dir)/$module/templates" "$module templates"
  done < <(context::get_array "modules.active" || true)

  home::staging::_layer_dir "$blueprints_dir/common/home" "blueprint common/home"

  local machine_type
  machine_type="$(context::get "machine_type" 2>/dev/null || true)"
  if [ -n "$machine_type" ]; then
    home::staging::_layer_dir "$blueprints_dir/machine_types/$machine_type/home" "blueprint machine_types/$machine_type/home"
  fi

  logging::success "Staging dir built at $_MK_HOME_STAGING_DIR"
}

home::staging::cleanup() {
  [ -n "$_MK_HOME_STAGING_DIR" ] || return 0
  rm -rf -- "$_MK_HOME_STAGING_DIR"
  _MK_HOME_STAGING_DIR=""
}

# --- helpers ---

# Dry-run gets a fresh temp dir each invocation, so it registers cleanup to keep
# from accumulating orphans in $TMPDIR. Real mode reuses a fixed cache path that
# is wiped and rebuilt each run, so it never accumulates — left in place as an
# inspectable artifact of the last (or a failed) run.
home::staging::_prepare_dir() {
  if input::is_dry_run; then
    _MK_HOME_STAGING_DIR=$(mktemp -d)
    lifecycle::register_cleanup home::staging::cleanup
  else
    _MK_HOME_STAGING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/staging"
    rm -rf -- "$_MK_HOME_STAGING_DIR"
    mkdir -p "$_MK_HOME_STAGING_DIR"
  fi
}

home::staging::_layer_dir() {
  local src="$1" label="$2"
  [ -d "$src" ] || return 0
  cp -R -- "$src"/. "$_MK_HOME_STAGING_DIR/"
  logging::debug "staging: layered $label"
}
