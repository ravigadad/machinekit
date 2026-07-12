#!/usr/bin/env bash
# hindsight_integration — wires this machine's coding agents to a Hindsight
# memory server. Hindsight integrates with many MCP agents (Claude Code, Codex,
# Cursor, …); the user picks which with the `integrations` array. Each agent's
# setup lives in a submodule (hindsight_integration/<agent>.sh) and they all
# share one config — server location, api port, bank prefix, and the fleet
# tenant key — so this is a single module, not one per agent.
#
# The tenant API key is the one secret every box must share. It's the named
# secret hindsight/tenant_api_key, resolved via secrets::resolve — an
# age-encrypted pool file or a secrets-manager reference — provide-or-generate,
# the same key the server uses. This module resolves it once and hands it, with
# the server URL, to each selected agent's config writer.

_HINDSIGHT_INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$_HINDSIGHT_INTEGRATION_DIR/hindsight/secrets.sh"
# Each submodule defines hindsight_integration::<agent>::{install, write_config,
# config_present} and optionally preflight/requires. Sourced here, not by
# source_all (which only auto-loads top-level module files).
for _hi_submodule in "$_HINDSIGHT_INTEGRATION_DIR/hindsight_integration"/*.sh; do
  [ -f "$_hi_submodule" ] || continue
  # shellcheck disable=SC1090
  source "$_hi_submodule"
done
unset _hi_submodule

# Depends on whichever backend resolves the shared tenant key: age for a pool
# file, secrets_manager for an explicit manager reference — derived from the
# declared secret (declared_secrets), so a convention-backed key resolved from an
# already-listed manager during preflight readiness adds no edge. Each selected
# integration also pulls in its own agent tool module. config::load runs before
# the resolver calls requires, so reading the integrations array here is safe.
hindsight_integration::requires() {
  hindsight_integration::declared_secrets | secrets::declared_backend_requirements
  local integration
  while IFS= read -r integration; do
    [ -n "$integration" ] || continue
    declare -F "hindsight_integration::${integration}::requires" >/dev/null 2>&1 \
      && "hindsight_integration::${integration}::requires"
  done < <(hindsight_integration::_integrations)
  # Pin success: the loop's exit status (non-zero when the last integration has
  # no optional requires — declare -F misses) would otherwise become this
  # function's return and silently trip the set -e caller.
  return 0
}

# Fail before any work on what's missing: the server location (server_url or
# server_host), a known integration set, and each selected agent's own
# preconditions. The tenant key is generated when absent (this box may be the
# first), so it is not required here.
hindsight_integration::preflight() {
  [ -n "$(hindsight_integration::_server_url)" ] \
    || [ -n "$(hindsight_integration::_server_host)" ] \
    || lifecycle::fail \
    "hindsight_integration: set [module.hindsight_integration] server_url, or server_host (the memory server's reachable host, typically its tailnet name)."
  local integration
  while IFS= read -r integration; do
    [ -n "$integration" ] || continue
    hindsight_integration::_is_available "$integration" || lifecycle::fail \
      "hindsight_integration: unknown integration '$integration'. Available: $(hindsight_integration::_available | paste -sd ' ' -)."
    declare -F "hindsight_integration::${integration}::preflight" >/dev/null 2>&1 \
      && "hindsight_integration::${integration}::preflight"
  done < <(hindsight_integration::_integrations)
  # Pin success (see requires): the loop's exit status must not become this
  # function's return, or a missing optional preflight silently trips set -e.
  return 0
}

# Declares the one secret this module uses: the fleet tenant key, shared by
# every box, provide-or-generate (generated when this box is the first).
hindsight_integration::declared_secrets() {
  printf '%s\ttrue\ttrue\n' "$(hindsight::secrets::name tenant_api_key)"
}

# Install each selected agent's integration software, then assemble the configs
# that point them at the server.
hindsight_integration::install() {
  logging::step "hindsight_integration install"
  local integration
  while IFS= read -r integration; do
    [ -n "$integration" ] || continue
    "hindsight_integration::${integration}::install"
  done < <(hindsight_integration::_integrations)
  hindsight_integration::_ensure_configs
}

# Create-once across the selected agents: write configs only for those missing
# one (an existing config may hold a tenant key the user has since propagated).
# The token is resolved ONCE and shared by every config written this run, so all
# agents on a box always carry the same key. Gated on dry-run: it writes a secret
# to disk and may generate the tenant key. Regenerate / repoint = delete the
# config(s) and re-apply.
hindsight_integration::_ensure_configs() {
  local pending=() integration
  while IFS= read -r integration; do
    [ -n "$integration" ] || continue
    "hindsight_integration::${integration}::config_present" || pending+=("$integration")
  done < <(hindsight_integration::_integrations)
  [ "${#pending[@]}" -gt 0 ] || return 0

  if input::is_dry_run; then
    logging::dry_run "would assemble Hindsight config for: ${pending[*]}"
    return 0
  fi

  # Standalone assignments, not `local x=$(…)`: resolve can lifecycle::fail (no
  # age key), and in local/argument position set -e can't see the failure.
  local url token prefix recall_banks tools_banks
  url="$(hindsight_integration::_api_url)"
  token="$(hindsight::secrets::resolve tenant_api_key)"
  prefix="$(hindsight_integration::_bank_id_prefix)"
  recall_banks="$(hindsight_integration::_auto_recall_banks)"
  tools_banks="$(hindsight_integration::_tool_use_banks)"
  for integration in "${pending[@]}"; do
    "hindsight_integration::${integration}::write_config" \
      "$url" "$token" "$prefix" "$recall_banks" "$tools_banks"
  done
  hindsight::secrets::provided tenant_api_key \
    || hindsight::secrets::announce_generated_tenant
}

# An integration is available iff its submodule was sourced — i.e. it defines a
# config writer. Single source of truth for both the list and the validity check.
hindsight_integration::_available() {
  declare -F \
    | sed -n 's/^declare -f hindsight_integration::\([a-z_][a-z0-9_]*\)::write_config$/\1/p' \
    | sort -u
}

hindsight_integration::_is_available() {
  declare -F "hindsight_integration::${1}::write_config" >/dev/null 2>&1
}

# The URL agents dial: server_url verbatim if set, else http://host:port. A
# non-standard setup (https, a path, a cloud host) goes in server_url; an agent
# config's own apiPort applies only to a local daemon.
hindsight_integration::_api_url() {
  local url
  url="$(hindsight_integration::_server_url)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    return 0
  fi
  printf 'http://%s:%s\n' \
    "$(hindsight_integration::_server_host)" \
    "$(hindsight_integration::_api_port)"
}

hindsight_integration::_integrations() {
  config::get_array "module.hindsight_integration.integrations"
}

hindsight_integration::_server_host() {
  config::get "module.hindsight_integration.server_host" --default ""
}

hindsight_integration::_server_url() {
  config::get "module.hindsight_integration.server_url" --default ""
}

hindsight_integration::_api_port() {
  config::get "module.hindsight_integration.api_port" --default "8888"
}

hindsight_integration::_bank_id_prefix() {
  config::get "module.hindsight_integration.bank_id_prefix" --default "coding"
}

# Banks whose memories fold into every session's auto-recall (read-only). A
# plain list of names — membership is the opt-in. `|| true`: an unset key makes
# config::get_array return 1, which a standalone $()-assignment would propagate
# under set -e; an empty list is the right answer there, not a failure.
hindsight_integration::_auto_recall_banks() {
  config::get_array "module.hindsight_integration.additional_banks.auto_recall" || true
}

# Banks exposed as their own MCP server with read/write tools. A plain list;
# membership is the opt-in (each carries a per-session context cost). See the
# note above re: `|| true`.
hindsight_integration::_tool_use_banks() {
  config::get_array "module.hindsight_integration.additional_banks.tool_use" || true
}
