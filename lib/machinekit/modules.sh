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
# Sourced eagerly at startup in the entry point's main shell, so every module
# function is defined before any subshell forks and is inherited by all of them
# (a call from inside a $()/pipe/process-substitution would strand the definitions
# in that subshell, out of reach of the rest of the run).
#
# Only top-level *.sh are auto-sourced as modules (plus capability satisfiers in
# capabilities/). A module that spans several files sources them itself.
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

# modules::collect HOOK — run <mod>::HOOK on each active module that defines it,
# forwarding their concatenated stdout. The read counterpart to run_preflights /
# run_post_apply: those drive hooks for their side effects; this gathers what a
# declarative hook (e.g. declared_secrets) emits.
modules::collect() {
  modules::_call_function_per_module "$1"
}

modules::_call_function_per_module() {
  local mod
  while IFS= read -r mod; do
    declare -F "${mod}::$1" > /dev/null 2>&1 || continue
    logging::debug "running ${mod}::$1"
    "${mod}::$1"
  done < <(context::get_array "modules.active")
}

# modules::capability_active CAPABILITY — true if any active module provides it.
# The mechanism for a soft, optional dependency: a module that integrates with a
# capability only when present (without `require`-ing it) asks here at run time.
modules::capability_active() {
  modules::capability_satisfier "$1" > /dev/null
}

# modules::capability_satisfier CAPABILITY — the name of the active module that
# provides CAPABILITY, or nothing (exit 1) if none does. Unlike
# capability_active's true/false, a caller that must dispatch to the concrete
# satisfier's own contract function (a capability whose satisfiers have
# genuinely divergent implementations, unlike container_manager's
# orbstack/docker_ce sharing one `docker` CLI) needs the name itself.
modules::capability_satisfier() {
  local capability="$1" mod provided
  while IFS= read -r mod; do
    declare -F "${mod}::provides" > /dev/null 2>&1 || continue
    while IFS= read -r provided; do
      [ "$provided" = "$capability" ] && { printf '%s\n' "$mod"; return 0; }
    done < <("${mod}::provides")
  done < <(context::get_array "modules.active")
  return 1
}
