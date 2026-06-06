#!/usr/bin/env bash
# Preflight orchestration.
#
# Resolves user inputs into context, fetches the blueprints into the local
# cache, then calls preflight on each active module so modules can fail
# fast on missing config before any changes happen.
#
# Precondition: jq must be on PATH (the data layer uses it).
[ -n "${_MK_PREFLIGHT_LOADED:-}" ] && return 0
_MK_PREFLIGHT_LOADED=1

preflight::run() {
  logging::step "Preflight: resolving inputs"

  system::detect
  blueprints::fetch
  config::load
  preflight::report_machine_type
  preflight::resolve_active_modules

  modules::run_preflights

  logging::success "Preflight complete."
}

preflight::report_machine_type() {
  local t
  t=$(context::get "machine_type") || true
  logging::info "Machine type: ${t:-not specified}"
}

preflight::resolve_active_modules() {
  local requested=() mod
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    requested+=("$mod")
  done < <(config::get_array "modules")

  [ "${#requested[@]}" -eq 0 ] && return 0

  local ordered=()
  while IFS= read -r mod; do
    ordered+=("$mod")
  done < <(resolver::resolve "${requested[@]}")

  context::set_array "modules.active" "${ordered[@]}"
  logging::info "Active modules: $(IFS=', '; printf '%s' "${ordered[*]}")"
}
