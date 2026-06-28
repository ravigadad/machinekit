#!/usr/bin/env bash
# Preflight orchestration.
#
# Resolves user inputs into context, fetches the blueprints into the local
# cache, builds the home staging tree, then calls preflight on each active
# module so modules can fail fast on missing config before any changes happen.
# Staging is built here (not in home::sync) so a module's preflight can ask
# home::will_exist whether a home file it depends on is going to be there.
#
# Precondition: jq must be on PATH (the data layer uses it).
[ -n "${_MK_PREFLIGHT_LOADED:-}" ] && return 0
_MK_PREFLIGHT_LOADED=1

preflight::run() {
  logging::step "Preflight: resolving inputs"

  preflight::resolve_inputs
  home::transforms::register_from_modules
  home::staging::build

  modules::run_preflights

  logging::success "Preflight complete."
}

# Resolve every input the run depends on without mutating the system or applying
# anything: detect the platform, fetch the blueprint, resolve the machine type,
# load config, and compute the active module set. Shared by apply's preflight and
# read-only commands (e.g. secrets listing) that need the resolved context but
# must not build staging or run module preflights.
preflight::resolve_inputs() {
  system::detect
  blueprints::fetch
  preflight::resolve_machine_type
  config::load
  preflight::resolve_active_modules
}

preflight::resolve_machine_type() {
  local t
  t=$(context::get "machine_type" --prompt "Which machine type do you want to apply?" --default "") || true
  logging::info "Machine type: ${t:-not specified}"
}

preflight::resolve_active_modules() {
  # Base modules are always active. The resolver dedups by name, so a blueprint
  # requesting one explicitly is harmless. The union is never empty, so there is
  # no empty-set short-circuit.
  # A machine type's `modules` replaces common's (the config merge carries arrays
  # whole), so `additional_modules` is the extend-don't-replace escape hatch. Each
  # key feeds the requested set through its own read — common's modules, then the
  # type's extras — kept independent so an absent `modules` still lets the extras in.
  local requested=("${MK_BASE_MODULES[@]}") mod
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    requested+=("$mod")
  done < <(config::get_array "modules")
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    requested+=("$mod")
  done < <(config::get_array "additional_modules")

  local ordered=()
  while IFS= read -r mod; do
    ordered+=("$mod")
  done < <(resolver::resolve "${requested[@]}")

  context::set_array "modules.active" "${ordered[@]}"
  logging::info "Active modules: $(IFS=', '; printf '%s' "${ordered[*]}")"
}
