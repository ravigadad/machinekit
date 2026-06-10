#!/usr/bin/env bash
# Module lifecycle orchestration — sourcing, preflight, and install.
[ -n "${_MK_MODULES_LOADED:-}" ] && return 0
_MK_MODULES_LOADED=1

_MK_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules"

# Framework-owned modules that are always active, independent of the blueprint's
# requested set. preflight::resolve_active_modules folds these into every run.
# Static and non-empty by design (the active set is therefore never empty).
# shellcheck disable=SC2034  # consumed in preflight.sh
MK_BASE_MODULES=(gomplate)

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
  modules::_call_function_per_module "preflight"
}

modules::run_installs() {
  modules::_call_function_per_module "install"
}

modules::run_post_apply() {
  modules::_call_function_per_module "post_apply"
}

modules::_call_function_per_module() {
  modules::source_all
  local mod
  while IFS= read -r mod; do
    declare -F "${mod}::$1" > /dev/null 2>&1 || continue
    "${mod}::$1"
  done < <(context::get_array "modules.active")
}
