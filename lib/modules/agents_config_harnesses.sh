#!/usr/bin/env bash
# agents_config_harnesses — projects the canonical agents config dir
# (~/.config/agents, owned by agents_config_setup) into each coding harness so
# the agent loads it: AGENTS.md instructions always-on, doctrine as
# load-when-relevant skills.
# Each harness's projection lives in a submodule (agents_config_harnesses/<harness>.sh)
# sharing one contract; the user picks which with the `harnesses` array.
#
# Sibling of agents_config_setup in the agents_config_ taxonomy — same category,
# no dependency between them. Projection assumes the dir is already present
# (cloned by setup, or synced in by Syncthing) and is a pure local, idempotent
# binding (a symlink + an import line), so it needs no consent gate.

_AGENTS_CONFIG_HARNESSES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each submodule defines agents_config_harnesses::<harness>::{requires, project,
# projection_present} (+ optional preflight). Sourced here, not by source_all
# (which only auto-loads top-level module files).
for _submodule_file in "$_AGENTS_CONFIG_HARNESSES_DIR/agents_config_harnesses"/*.sh; do
  [ -f "$_submodule_file" ] || continue
  # shellcheck disable=SC1090
  source "$_submodule_file"
done
unset _submodule_file

# Each selected harness pulls in its own agent tool module. config::load runs
# before the resolver calls requires, so reading the harnesses array is safe.
agents_config_harnesses::requires() {
  local harness
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    declare -F "agents_config_harnesses::${harness}::requires" >/dev/null 2>&1 \
      && "agents_config_harnesses::${harness}::requires"
  done < <(agents_config_harnesses::_harnesses)
  # Pin success: the loop's exit status (non-zero when the last harness has no
  # optional requires — declare -F misses) would otherwise become this
  # function's return and silently trip the set -e caller.
  return 0
}

# Fail before any work on an unknown harness; dispatch each harness's own
# preflight if it defines one. An empty/missing harnesses list is a clean no-op.
agents_config_harnesses::preflight() {
  local harness
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    agents_config_harnesses::_is_available "$harness" || lifecycle::fail \
      "agents_config_harnesses: unknown harness '$harness'. Available: $(agents_config_harnesses::_available | paste -sd ' ' -)."
    declare -F "agents_config_harnesses::${harness}::preflight" >/dev/null 2>&1 \
      && "agents_config_harnesses::${harness}::preflight"
  done < <(agents_config_harnesses::_harnesses)
  # Pin success (see requires): a missing optional preflight must not become this
  # function's return and trip set -e.
  return 0
}

# Project the agents config dir into each configured harness not already
# projected. Idempotent; gated on dry-run (projection creates a symlink and
# edits a config file).
agents_config_harnesses::install() {
  logging::step "agents_config_harnesses install"
  local agents_config_dir pending_harnesses=() harness
  agents_config_dir="$(agents_config_harnesses::_agents_dir)"
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    "agents_config_harnesses::${harness}::projection_present" "$agents_config_dir" \
      || pending_harnesses+=("$harness")
  done < <(agents_config_harnesses::_harnesses)
  [ "${#pending_harnesses[@]}" -gt 0 ] || return 0

  if input::is_dry_run; then
    logging::dry_run "would project the agents config ($agents_config_dir) into: ${pending_harnesses[*]}"
    return 0
  fi
  for harness in "${pending_harnesses[@]}"; do
    "agents_config_harnesses::${harness}::project" "$agents_config_dir"
  done
}

# A harness is available iff its submodule was sourced — i.e. it defines a
# project function. Single source of truth for both the list and the check.
agents_config_harnesses::_available() {
  declare -F \
    | sed -n 's/^declare -f agents_config_harnesses::\([a-z_][a-z0-9_]*\)::project$/\1/p' \
    | sort -u
}

agents_config_harnesses::_is_available() {
  declare -F "agents_config_harnesses::${1}::project" >/dev/null 2>&1
}

# Optional: missing/empty means project nothing. `|| true`: an unset key makes
# config::get_array return 1, which a standalone $()-assignment would propagate
# under set -e; an empty list is the right answer there, not a failure.
agents_config_harnesses::_harnesses() {
  config::get_array "module.agents_config_harnesses.harnesses" || true
}

# The dir is owned by the sibling agents_config_setup module (which puts it on
# the machine); projection only reads it. Default is the XDG convention, so this
# works standalone before agents_config_setup exists.
agents_config_harnesses::_agents_dir() {
  config::get "module.agents_config_setup.dir" --default "$HOME/.config/agents"
}
