#!/usr/bin/env bash
# Module lifecycle orchestration — sourcing, preflight, and install.
[ -n "${_MK_MODULES_LOADED:-}" ] && return 0
_MK_MODULES_LOADED=1

_MK_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules"

modules::dir() {
  printf '%s\n' "$_MK_MODULES_DIR"
}

# Source all module files once. Idempotent via _MK_MODULES_SOURCED guard.
# Called by the resolver when it needs to discover capability satisfiers.
modules::source_all() {
  [ -n "${_MK_MODULES_SOURCED:-}" ] && return 0
  _MK_MODULES_SOURCED=1
  local f
  # shellcheck disable=SC1090
  for f in "$_MK_MODULES_DIR"/*.sh "$_MK_MODULES_DIR"/capabilities/*.sh; do
    [ -f "$f" ] || continue
    source "$f"
  done
}

modules::run_preflights() {
  modules::source_all
  local mod
  while IFS= read -r mod; do
    declare -f "${mod}::preflight" > /dev/null 2>&1 || continue
    "${mod}::preflight"
  done < <(context::get_array "modules.active")
}

modules::run_installs() {
  modules::source_all
  local mod
  while IFS= read -r mod; do
    "${mod}::install"
  done < <(context::get_array "modules.active")
}
