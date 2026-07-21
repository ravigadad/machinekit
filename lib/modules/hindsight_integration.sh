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
# shellcheck source-path=SCRIPTDIR
source "$_HINDSIGHT_INTEGRATION_DIR/hindsight/banks.sh"
# Each submodule defines hindsight_integration::<agent>::{install, write_config,
# config_present} and optionally preflight/requires. Sourced here, not by
# source_all (which only auto-loads top-level module files).
for _hi_submodule in "$_HINDSIGHT_INTEGRATION_DIR/hindsight_integration"/*.sh; do
  [ -f "$_hi_submodule" ] || continue
  # shellcheck disable=SC1090
  source "$_hi_submodule"
done
unset _hi_submodule

# A module constant, not an inline literal, so a test can stub context::get on the
# exact --prompt argument (machinekit-testing-principles exact-arg stubbing).
_HINDSIGHT_INTEGRATION_CONSENT_PROMPT="Apply bank missions/dispositions to the Hindsight tenant now? (y/n)"

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

# Soft ordering edge: on a box that also runs the memory server, order this
# module after hindsight_server so the local server is up (post_apply order) when
# the bank-config upsert PATCHes it. Deliberately not `require` — a client points
# at a remote server it doesn't run, and an ::after to an inactive hindsight_server
# is silently ignored, so this couples the two only where both are present. The
# server's first cold boot can still outlast its health check, so the upsert's
# skip-and-retry fallback remains the guarantee; this only removes the certain miss.
hindsight_integration::after() {
  printf 'hindsight_server\n'
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
  hindsight_integration::_validate_bank_configs
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
}

# Configure the tenant's banks (missions/dispositions) from this machine, once
# the server it points at is up. Post-apply because it needs the live API — on a
# client the server is remote and already running; on a box that also serves, its
# hindsight_server post_apply may or may not have run first, so an unreachable
# server is a skip, not a failure (it lands on the next apply). Mutating the
# tenant is consent-gated (the explicit-consent rule); the upsert is idempotent,
# so any machine carrying config for a bank re-asserts it on apply.
hindsight_integration::post_apply() {
  hindsight_integration::_has_bank_configs || return 0
  if input::is_dry_run; then
    logging::dry_run "would apply Hindsight bank config (consent-gated) for: $(hindsight_integration::_configured_bank_names | paste -sd ' ' -)"
    return 0
  fi
  if ! hindsight_integration::_configure_banks_consented; then
    context::set "hindsight_integration.bank_config" unconsented
    logging::warn "hindsight_integration: bank config not consented; the tenant is left as-is. Set MACHINEKIT_HINDSIGHT_INTEGRATION_CONFIGURE_BANKS=1 to apply."
    return 0
  fi
  hindsight_integration::_configure_banks
}

# Standalone assignment for the url: _api_url can lifecycle::fail, and in
# local/argument position set -e can't see the failure.
hindsight_integration::_configure_banks() {
  local url token tenant bank body
  # A not-yet-shared key is the only soft skip: resolving one and using it would
  # mint a fresh token that doesn't match the server's. This is deliberately the
  # `provided` check, not a token resolution — an undecryptable/rotated shared key
  # is a real failure the resolve below surfaces fatally, not a "not shared" skip.
  if ! hindsight::secrets::provided tenant_api_key; then
    context::set "hindsight_integration.bank_config" tenant_unshared
    logging::warn "hindsight_integration: the fleet tenant key ($(hindsight::secrets::name tenant_api_key)) isn't shared yet (pool/manager); skipping bank config. Add it to your secrets manager and re-apply."
    return 0
  fi
  url="$(hindsight_integration::_api_url)"
  if ! hindsight::banks::server_reachable "$url"; then
    context::set "hindsight_integration.bank_config" unreachable
    logging::warn "hindsight_integration: $url not reachable; skipping bank config — it will apply on the next run once the server is up."
    return 0
  fi
  # Standalone assignment (not `local x=$(…)`): the key is provided, so this takes
  # secrets::resolve's provided branch, and a decrypt/fetch failure there must
  # propagate fatally under set -e rather than be swallowed.
  token="$(hindsight::secrets::resolve tenant_api_key)"
  tenant="$(hindsight_integration::_bank_config_tenant)"
  while IFS= read -r bank; do
    [ -n "$bank" ] || continue
    body="$(hindsight_integration::_bank_config_json "$bank")"
    logging::info "hindsight_integration: configuring bank '$bank'..."
    hindsight::banks::configure "$url" "$token" "$tenant" "$bank" "$body"
  done < <(hindsight_integration::_configured_bank_names)
  context::set "hindsight_integration.bank_config" applied
  logging::success "hindsight_integration: applied bank config to the Hindsight tenant."
}

# postflight: what this machine wired up — the coding agents now pointed at the
# memory server.
hindsight_integration::postflight_info() {
  local integrations="" integration
  while IFS= read -r integration; do
    [ -n "$integration" ] || continue
    integrations="${integrations:+$integrations, }$integration"
  done < <(hindsight_integration::_integrations)
  [ -n "$integrations" ] || return 0
  printf 'Wired %s to the Hindsight server at %s.\n' \
    "$integrations" "$(hindsight_integration::_api_url)"
}

# postflight: the steps still on the operator — share the fleet tenant key (only
# when this box doesn't also serve, since hindsight_server owns that line there),
# and re-run bank config if it was skipped for a reason the operator resolves.
hindsight_integration::postflight_instructions() {
  if ! hindsight::secrets::provided tenant_api_key \
      && ! hindsight_integration::_hindsight_server_active; then
    printf 'The fleet tenant key (%s) is not in your secrets manager — every hindsight box must resolve the same one. Add it and re-apply.\n' \
      "$(hindsight::secrets::name tenant_api_key)"
  fi
  case "$(hindsight_integration::_bank_config_outcome)" in
    unconsented)
      printf 'Bank missions were not applied (consent withheld) — re-apply with MACHINEKIT_HINDSIGHT_INTEGRATION_CONFIGURE_BANKS=1.\n' ;;
    unreachable)
      printf 'Bank missions were not applied (the Hindsight server was unreachable) — bring it up and re-apply.\n' ;;
    # tenant_unshared is covered by the tenant-key step above; applied/unset need nothing.
  esac
}

# The recorded outcome of this run's bank-config attempt (applied / unconsented /
# tenant_unshared / unreachable), or empty when no banks are configured or the
# run was dry. Lets postflight surface the operator's next step without
# re-attempting the mutation.
hindsight_integration::_bank_config_outcome() {
  context::get "hindsight_integration.bank_config" --default ""
}

# Whether this box also runs the memory server. On such a box hindsight_server
# owns the shared-tenant-key instruction, so this module defers to it (avoiding a
# duplicate line under two module headers).
hindsight_integration::_hindsight_server_active() {
  context::get_array "modules.active" | grep -qxF "hindsight_server"
}

# Default false: the upsert can overwrite a bank's config (including manual
# edits), so the remote write never happens without an explicit yes.
hindsight_integration::_configure_banks_consented() {
  local consent
  consent="$(context::get "hindsight_integration.configure_banks" --default false --coerce boolean \
    --prompt "$_HINDSIGHT_INTEGRATION_CONSENT_PROMPT")"
  [ "$consent" = "true" ]
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
  config::get_array "module.hindsight_integration.auto_recall_banks" || true
}

# Banks exposed as their own MCP server with read/write tools. A plain list;
# membership is the opt-in (each carries a per-session context cost). See the
# note above re: `|| true`.
hindsight_integration::_tool_use_banks() {
  config::get_array "module.hindsight_integration.tool_use_banks" || true
}

# The per-bank config tables ({} when absent). Independent of the recall/tool_use
# wiring lists above: a bank configured here need not be wired into this box, and
# vice versa — the two axes don't have to line up.
hindsight_integration::_bank_configs_json() {
  config::get_json "module.hindsight_integration.additional_banks" '{}'
}

hindsight_integration::_configured_bank_names() {
  hindsight_integration::_bank_configs_json | jq -r 'keys_unsorted[]'
}

hindsight_integration::_bank_config_json() {
  local bank="$1"
  hindsight_integration::_bank_configs_json | jq -c --arg bank "$bank" '.[$bank]'
}

hindsight_integration::_has_bank_configs() {
  [ -n "$(hindsight_integration::_configured_bank_names)" ]
}

# Called unconditionally by preflight: validate_shape treats no-banks ({}) as
# valid, so there's no guard to branch on — preflight keeps a single flow.
hindsight_integration::_validate_bank_configs() {
  hindsight::banks::validate_shape "$(hindsight_integration::_bank_configs_json)"
}

# The tenant path segment. "default" is Hindsight's conventional single-tenant
# name (ApiKeyTenantExtension); override only for a multi-tenant server.
hindsight_integration::_bank_config_tenant() {
  config::get "module.hindsight_integration.tenant" --default "default"
}
