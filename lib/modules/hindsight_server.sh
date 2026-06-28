#!/usr/bin/env bash
# hindsight_server — runs a self-hosted Hindsight agent-memory API as a single
# container backed by the host's postgres. This module owns only the Hindsight
# service; the database engine is the postgres module's job, pulled in by
# dependency. A machine is a memory server purely because its blueprint lists
# hindsight_server — there is no machine-type branching here.
#
# Secrets come from the blueprint pool (secrets/hindsight/*.age), not the home
# pipeline. machinekit assembles them — provided-or-generated — into a create-
# once ~/.config/hindsight/hindsight.env (mode 600): the container's env_file and
# the readable record of any generated values. The LLM key must be provided; the
# tenant key and DB password are generated if absent. This module reads the DB
# password back from that file to provision the matching postgres role. The env
# file is assembled in install (it needs no decrypted home content); role
# provisioning and compose-up run in post_apply, after the container runtime and
# postgres access (the postgres module's post_apply) are in place.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hindsight/secrets.sh"

# The full image (not -slim) at :latest — it bundles the embedding/reranking
# models, whereas -slim would need external providers we don't configure. Like
# brew formulae and the other modules, machinekit tracks upstream rather than
# pinning. Overridable from [module.hindsight_server].
_HINDSIGHT_SERVER_DEFAULT_IMAGE="ghcr.io/vectorize-io/hindsight:latest"
_HINDSIGHT_SERVER_DEFAULT_DB="hindsight"
_HINDSIGHT_SERVER_DEFAULT_USER="hindsight"
_HINDSIGHT_SERVER_DEFAULT_API_PORT="8888"
_HINDSIGHT_SERVER_DEFAULT_UI_PORT="9999"

# All unconditional: the resolver guarantees a container runtime, postgres, and
# age land in modules.active whenever this module is requested. age is required
# because the env file is assembled from the encrypted secrets pool — without it
# active, the age key is never installed and llm_api_key.age can't be decrypted.
hindsight_server::requires() {
  printf 'container_manager\n'
  printf 'postgres\n'
  printf 'age\n'
}

# Fail before any work if the blueprint hasn't supplied what the server can't run
# without: an LLM provider (no default — the operator must choose one) and the
# LLM API key. The tenant key and DB password are generated when absent, so they
# are not required here.
hindsight_server::preflight() {
  [ -n "$(hindsight_server::_llm_provider)" ] || lifecycle::fail \
    "hindsight_server: set [module.hindsight_server] llm_provider in your blueprint config."
  hindsight_server::_llm_key_available || lifecycle::fail \
    "hindsight_server: supply the LLM API key at $(hindsight::secrets::rel llm_api_key), or an already-assembled ~/$(hindsight_server::_env_rel)."
}

# The LLM key is the one secret machinekit cannot generate. It is satisfied
# either by the provided pool secret or by an env file already assembled on a
# prior run (which we never rebuild).
hindsight_server::_llm_key_available() {
  hindsight::secrets::provided llm_api_key || [ -f "$(hindsight_server::_env_path)" ]
}

# Declares the pool secrets this module assembles into the env file. The LLM key
# is provide-only (required); the tenant key, DB password, and control-plane
# password are generated when absent.
hindsight_server::pool_secrets() {
  printf '%s\ttrue\tfalse\n' "$(hindsight::secrets::rel llm_api_key)"
  printf '%s\ttrue\ttrue\n'  "$(hindsight::secrets::rel tenant_api_key)"
  printf '%s\ttrue\ttrue\n'  "$(hindsight::secrets::rel db_password)"
  printf '%s\ttrue\ttrue\n'  "$(hindsight::secrets::rel cp_access_key)"
}

# Engine-level prep plus the env file. The postgres primitives, brew, and the
# env assembly are each dry-run-aware, so install delegates rather than branching
# on dry-run itself. Host-postgres network access is the postgres module's job
# (its post_apply), so nothing here opens it.
hindsight_server::install() {
  logging::step "hindsight_server install"
  brew::install_formula pgvector
  hindsight_server::_provision_database
  hindsight_server::_ensure_env_file
  hindsight_server::_place_compose
}

# Runs after the container runtime and host-postgres access are up (postgres's
# post_apply). The role and compose-up are side-effecting, so a single dry-run
# gate covers the whole hook.
hindsight_server::post_apply() {
  if input::is_dry_run; then
    logging::dry_run "would provision the hindsight db role, start the server (docker compose up -d), and health-check the API"
    return 0
  fi
  hindsight_server::_provision_role
  hindsight_server::_compose_up
  hindsight_server::_health_check
}

# Order is the contract: the extension can only be created in a database that
# already exists.
hindsight_server::_provision_database() {
  postgres::ensure_database "$(hindsight_server::_db_name)"
  postgres::ensure_extension "$(hindsight_server::_db_name)" vector
}

hindsight_server::_provision_role() {
  # Resolve into locals first: _db_password can lifecycle::fail, and in argument
  # position ("$(…)") that exit is swallowed by the command substitution — the
  # role would be created with an empty password. A standalone assignment lets
  # set -e propagate the failure.
  local db_user db_password
  db_user="$(hindsight_server::_db_user)"
  db_password="$(hindsight_server::_db_password)"
  postgres::ensure_role "$db_user" "$db_password"
  # _provision_database (install) created the db under the postgres superuser,
  # before this role existed. Now that it does, hand it ownership so the
  # container's startup migrations (DDL) can run.
  postgres::ensure_database "$(hindsight_server::_db_name)" "$db_user"
}

# Assemble-once: if the env file is already present, never touch it — it may hold
# generated secrets the user has since propagated to other boxes. Otherwise build
# it from the pool. Regenerate = delete the file and re-apply (ensure_role then
# reconciles the postgres role to the new password). The whole act is gated on
# dry-run here because it writes secrets to disk and may generate tokens.
hindsight_server::_ensure_env_file() {
  local env_path
  env_path="$(hindsight_server::_env_path)"
  if [ -f "$env_path" ]; then
    logging::info "hindsight_server: reusing existing $env_path"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would assemble $env_path (mode 600) from secrets/hindsight/*"
    return 0
  fi
  hindsight_server::_assemble_env_file "$env_path"
}

# Resolve the three secrets (provide-or-generate), write the 600 env file, then
# announce any that were generated. Standalone assignments, not `local x=$(…)`:
# resolution can lifecycle::fail (missing LLM key or age key) and in local/
# argument position the failing command substitution is swallowed by set -e.
hindsight_server::_assemble_env_file() {
  local env_path="$1" llm tenant db_password cp_access
  llm="$(hindsight_server::_resolve_llm_key)"
  tenant="$(hindsight::secrets::resolve tenant_api_key)"
  db_password="$(hindsight::secrets::resolve db_password)"
  # The cp access key self-announces when generated (see _resolve_cp_access_key):
  # whether it was generated vs. typed isn't a re-derivable predicate like the
  # others, and this runs in a $() subshell, so a flag set here wouldn't survive.
  cp_access="$(hindsight_server::_resolve_cp_access_key "$env_path")"
  hindsight_server::_write_env_file "$env_path" "$llm" "$tenant" "$db_password" "$cp_access"
  hindsight::secrets::provided tenant_api_key \
    || hindsight::secrets::announce_generated_tenant "$env_path" "HINDSIGHT_API_TENANT_API_KEY"
  hindsight::secrets::provided db_password || hindsight_server::_announce_db_password
}

# The LLM key is provide-only; fail loudly rather than generate a useless one.
# (preflight already checks availability; this guards the assemble path directly.)
hindsight_server::_resolve_llm_key() {
  hindsight::secrets::provided llm_api_key || lifecycle::fail \
    "hindsight_server: the LLM API key ($(hindsight::secrets::rel llm_api_key)) is required to assemble the env file."
  hindsight::secrets::resolve llm_api_key
}

# The control-plane UI password (HINDSIGHT_CP_ACCESS_KEY) — gates the web UI.
# Server-local, not fleet-shared, so it is NOT the tenant key. Resolution order:
# a provided pool secret wins; otherwise an interactive operator may type one
# (entered via the --secret prompt); a blank entry or a non-interactive run
# generates one. The generate
# path announces here (to stderr) because this runs in a $() subshell where a
# returned flag would be lost, and "generated vs. typed" isn't re-derivable.
hindsight_server::_resolve_cp_access_key() {
  local env_path="$1" entered
  if hindsight::secrets::provided cp_access_key; then
    hindsight::secrets::resolve cp_access_key
    return 0
  fi
  if entered=$(context::get "module.hindsight_server.cp_access_key" \
      --prompt "Set a control-plane UI password (leave blank to generate one)" --secret); then
    printf '%s\n' "$entered"
    return 0
  fi
  hindsight::secrets::resolve cp_access_key
  hindsight_server::_announce_cp_access "$env_path"
}

hindsight_server::_write_env_file() {
  local env_path="$1" llm="$2" tenant="$3" db_password="$4" cp_access="$5" dir
  dir="$(dirname "$env_path")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  { printf 'HINDSIGHT_API_LLM_API_KEY=%s\n' "$llm"
    printf 'HINDSIGHT_API_TENANT_API_KEY=%s\n' "$tenant"
    printf 'HINDSIGHT_CP_DATAPLANE_API_KEY=%s\n' "$tenant"
    printf 'HINDSIGHT_CP_ACCESS_KEY=%s\n' "$cp_access"
    printf 'MACHINEKIT_HINDSIGHT_DB_PASSWORD=%s\n' "$db_password"
  } > "$env_path"
  chmod 600 "$env_path"
}

# Quiet: the DB password is machine-local. Pointed at the file (never the value)
# for the curious; not needed elsewhere, and regeneration reconciles the role.
hindsight_server::_announce_db_password() {
  logging::info "hindsight_server: generated a database password in $(hindsight_server::_env_path) (MACHINEKIT_HINDSIGHT_DB_PASSWORD). It is machine-local; regeneration reconciles the postgres role automatically."
}

# Loud: a generated control-plane password must be retrieved to sign in to the
# web UI. Points at the file, never the value.
hindsight_server::_announce_cp_access() {
  logging::banner warn "Generated a control-plane UI password in $1 (HINDSIGHT_CP_ACCESS_KEY).
Retrieve it from that file to sign in to the web UI; it is machine-local."
}

# Module-owned, not a home dotfile: the compose is operational runtime state, so
# this module writes it directly rather than layering it through home::sync.
hindsight_server::_place_compose() {
  if input::is_dry_run; then
    logging::dry_run "would write the hindsight compose file to $(hindsight_server::_compose_path)"
    return 0
  fi
  mkdir -p "$(dirname "$(hindsight_server::_compose_path)")"
  hindsight_server::_render_compose > "$(hindsight_server::_compose_path)"
}

# Renders the single-service compose. The container joins the external machinekit
# network (created by the container runtime / postgres access in post_apply) so
# its source IP falls in the subnet host postgres authorized — otherwise pg_hba
# rejects it. Secrets come from env_file; the non-secret config/derived vars are
# set inline. DATABASE_URL carries a literal ${MACHINEKIT_HINDSIGHT_DB_PASSWORD}
# placeholder, resolved by docker from --env-file at up-time, so no plaintext
# password sits in the compose file on disk.
#
# VERIFY IN VM. The env-var contract and the host-gateway mapping are from the
# upstream config reference, not a live run — confirm the keys the image actually
# reads and that extra_hosts resolves before trusting this shape.
hindsight_server::_render_compose() {
  local db_url model model_line="" base_url base_url_line=""
  db_url="$(hindsight_server::_database_url)"
  # Pre-resolve the optional model/base-url lines (newline-prefixed when set,
  # empty when not) rather than escaping quotes inside the heredoc, where \" wouldn't.
  model="$(hindsight_server::_llm_model)"
  [ -n "$model" ] && model_line=$'\n'"      HINDSIGHT_API_LLM_MODEL: \"$model\""
  base_url="$(hindsight_server::_llm_base_url)"
  [ -n "$base_url" ] && base_url_line=$'\n'"      HINDSIGHT_API_LLM_BASE_URL: \"$base_url\""
  cat <<YAML
services:
  hindsight:
    image: $(hindsight_server::_image)
    restart: unless-stopped
    ports:
      - "$(hindsight_server::_api_port):8888"
      - "$(hindsight_server::_ui_port):9999"
    env_file:
      - $(hindsight_server::_env_path)
    environment:
      HINDSIGHT_API_LLM_PROVIDER: "$(hindsight_server::_llm_provider)"$model_line$base_url_line
      HINDSIGHT_API_TENANT_EXTENSION: "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension"
      HINDSIGHT_API_DATABASE_URL: "$db_url"
      HINDSIGHT_API_PORT: "8888"
      HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP: "true"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - machinekit
networks:
  machinekit:
    external: true
YAML
}

# The container's DATABASE_URL. connection_string yields a passwordless URL for
# the host-reaching alias; we splice the literal ${MACHINEKIT_HINDSIGHT_DB_PASSWORD}
# placeholder in after the user so docker resolves it from --env-file at up-time.
hindsight_server::_database_url() {
  # Literal on purpose: the placeholder must reach the compose file unexpanded.
  # shellcheck disable=SC2016
  local placeholder='${MACHINEKIT_HINDSIGHT_DB_PASSWORD}' base
  base="$(postgres::connection_string "$(hindsight_server::_db_name)" "$(hindsight_server::_db_user)" container)"
  printf '%s\n' "${base/@/:${placeholder}@}"
}

# Routed through container_manager::_docker so it gets the OS-correct invocation:
# `sudo docker` on Linux (root daemon, user not in the docker group), bare docker
# on macOS/OrbStack. Same reason the network creation in postgres::access works.
hindsight_server::_compose_up() {
  container_manager::_docker compose \
    -f "$(hindsight_server::_compose_path)" \
    --env-file "$(hindsight_server::_env_path)" up -d
}

# Poll readiness rather than probe once: the container runs migrations and (on the
# full image) loads ML models on first boot, so it isn't up the instant compose
# returns. Give up after a bounded wait with a non-fatal warn that says how to
# check later — a first-ever boot can exceed any sane wait, and that shouldn't
# fail the apply.
hindsight_server::_health_check() {
  local url attempts=15 delay=2 i
  url="http://localhost:$(hindsight_server::_api_port)/health"
  # The poll can take several seconds (more on a cold first boot); say so, or the
  # silent wait reads as a hang.
  logging::info "hindsight_server: started; polling $url for readiness (up to $(( attempts * delay ))s)..."
  for (( i = 1; i <= attempts; i++ )); do
    curl -fsS "$url" >/dev/null 2>&1 && { logging::success "hindsight_server: API is healthy."; return 0; }
    sleep "$delay"
  done
  logging::warn "hindsight_server: API not healthy after $(( attempts * delay ))s; it may still be starting (first boot loads ML models). Check later with: curl -fsS $url"
}

# Reads KEY=value from the assembled env file without sourcing it (avoid
# executing a file that holds arbitrary secret values).
hindsight_server::_db_password() {
  local line
  line=$(grep -m1 "^MACHINEKIT_HINDSIGHT_DB_PASSWORD=" "$(hindsight_server::_env_path)") \
    || lifecycle::fail "hindsight_server: MACHINEKIT_HINDSIGHT_DB_PASSWORD not found in $(hindsight_server::_env_path)"
  printf '%s\n' "${line#*=}"
}

# The assembled env file's home-relative destination. Home-relative (not just an
# absolute path) so error messages can show it as ~/… without leaking $HOME.
hindsight_server::_env_rel() {
  printf '.config/hindsight/hindsight.env\n'
}

hindsight_server::_env_path() {
  printf '%s/%s\n' "$HOME" "$(hindsight_server::_env_rel)"
}

hindsight_server::_compose_path() {
  printf '%s/.config/hindsight/docker-compose.yaml\n' "$HOME"
}

hindsight_server::_llm_provider() {
  config::get "module.hindsight_server.llm_provider" --default ""
}

# Optional: when unset, Hindsight applies its own default, so machinekit omits the
# var rather than pinning a provider-specific model the operator didn't choose.
hindsight_server::_llm_model() {
  config::get "module.hindsight_server.llm_model" --default ""
}

# Optional: override the provider's API base URL (e.g. Azure OpenAI, a local
# endpoint). Unset → omitted, so Hindsight uses the provider's default base URL.
hindsight_server::_llm_base_url() {
  config::get "module.hindsight_server.llm_base_url" --default ""
}

hindsight_server::_db_name() {
  config::get "module.hindsight_server.db_name" --default "$_HINDSIGHT_SERVER_DEFAULT_DB"
}

hindsight_server::_db_user() {
  config::get "module.hindsight_server.db_user" --default "$_HINDSIGHT_SERVER_DEFAULT_USER"
}

hindsight_server::_image() {
  config::get "module.hindsight_server.image" --default "$_HINDSIGHT_SERVER_DEFAULT_IMAGE"
}

# The API host port. Only the published (host) side of the mapping — the
# container always listens on 8888 (HINDSIGHT_API_PORT is pinned there), so the
# health check, which dials the host port, reaches it via the mapping.
hindsight_server::_api_port() {
  config::get "module.hindsight_server.api_port" --default "$_HINDSIGHT_SERVER_DEFAULT_API_PORT"
}

# The control plane (web UI) host port — likewise host-side only. Hindsight
# exposes no env var to move the container's internal control-plane port (fixed
# at 9999), so this just sets the published side of the mapping.
hindsight_server::_ui_port() {
  config::get "module.hindsight_server.ui_port" --default "$_HINDSIGHT_SERVER_DEFAULT_UI_PORT"
}
