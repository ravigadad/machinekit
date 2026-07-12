#!/usr/bin/env bash
# infisical — secrets_manager capability satisfier backed by Infisical Cloud.
# Self-hosting is out of scope for this module; it always talks to Infisical's
# hosted cloud API.
#
# Two auth methods (module.infisical.auth_method), typically machine-type
# layered — personal/attended machines want "user", headless ones "universal":
#   universal — a machine identity (client_id + client_secret) exchanges for a
#               short-lived access token via `infisical login`. Works in both
#               interactive and non-interactive mode; the only path that works
#               non-interactively.
#   user      — browser/SSO login. No credential for machinekit to resolve:
#               `infisical login` opens a browser itself and stores the
#               session in the OS keyring. Interactive-only — federated SSO
#               has no password to hand over programmatically, and a prior
#               session isn't portable to a new machine — so readiness
#               hard-fails immediately in a non-interactive run, rather than
#               failing confusingly deep inside an impossible login.
#
# The universal-auth access token lives only in a plain shell variable for
# this run's duration — never through context::set, which persists to a
# plaintext file on disk (matching secrets::put::_prompt_value's identical
# discipline for a secret value).
_INFISICAL_TOKEN=""

# The default project/env's secret keys, captured once at readiness so existence
# checks (infisical::has) are local lookups, not a network probe per secret. Only
# keys are kept — values stream through the jq filter and are never stored. Empty
# before readiness, or when no default project is configured.
_INFISICAL_SECRET_NAMES=""

# The explicit infisical:// references (from [secrets.manager_refs]) confirmed to
# resolve, captured once at readiness so backend_for can trust an explicit ref by
# a local lookup rather than assuming it — an explicit ref may address any
# project/env, so it can't be answered from the default-project key cache above
# and gets its own per-reference probe. Empty before readiness.
_INFISICAL_VERIFIED_REFERENCES=""

infisical::provides() { printf 'secrets_manager\n'; }

# Ready the manager for use: install the CLI and authenticate, so downstream
# presence checks and fetches have a live session. Runs before any module resolves
# a secret — not in the install phase — because truthful presence must be knowable
# while validating; the minted universal token / keyring user session then carries
# through the run.
# In dry-run it still happens (a login is read-only, and preflight must be able
# to tell whether a manager-backed secret actually exists); the message says so,
# since authenticating is the one outward action a dry-run takes.
infisical::ensure_ready() {
  logging::step "infisical"
  # --override-dry-run: the CLI is a genuine prerequisite for the readiness this
  # function performs even under --dry-run (authenticate + read the inventory),
  # so it must actually install — mirroring gomplate, which needs its binary to
  # render dry-run diffs. Without this, a dry-run on a machine lacking the CLI
  # would skip the install and then abort on a missing `infisical` binary.
  brew::install_formula "infisical" --override-dry-run
  if input::is_dry_run; then
    logging::info "infisical: installing the CLI and authenticating to read the secret inventory — a prerequisite for resolving secret sources; nothing else is mutated in dry-run."
  fi
  infisical::_authenticate
  infisical::_load_secret_names
  infisical::_verify_explicit_references
}

# Authenticate per the configured method. user auth can't proceed
# non-interactively (federated SSO has no programmatic credential), so fail
# early and clearly rather than deep inside an impossible browser login.
infisical::_authenticate() {
  case "$(infisical::_auth_method)" in
    universal)
      _INFISICAL_TOKEN=$(infisical::_login_universal)
      # The client secret was needed only for that one login exchange. Scrub it
      # from the environment so it is not inherited by the children machinekit
      # later forks — gomplate renders expose the whole environment to templates
      # via .Env, and hooks/brew/etc. inherit it too. The short-lived access
      # token, not the identity's non-expiring root credential, carries the run.
      unset "$(context::env_var_name "infisical.client_secret")"
      ;;
    user)
      input::is_interactive || lifecycle::fail \
        "infisical: auth_method = user requires an interactive session; set auth_method = universal for headless machines."
      infisical::_login_user ;;
    *)
      lifecycle::fail "infisical: unknown auth_method '$(infisical::_auth_method)' — expected 'universal' or 'user'." ;;
  esac
}

# Capture the default project/env's secret keys into the cache. With no default
# project configured there is nothing to resolve by convention, so skip the
# export (an empty --projectId would be a broken call) and leave the cache empty
# — every convention name then reads as absent, the truthful answer. A reachable
# but failing export propagates under set -e: if the inventory can't be read,
# presence can't be answered, so readiness fails loudly rather than guessing.
infisical::_load_secret_names() {
  local project_id
  project_id="$(infisical::_default_project_id)"
  if [ -z "$project_id" ]; then
    _INFISICAL_SECRET_NAMES=""
    return 0
  fi
  _INFISICAL_SECRET_NAMES="$(infisical::_export_secret_keys "$project_id" "$(infisical::_environment)")"
}

# The root-path secret keys in a project/env, one per line. The Infisical CLI has
# no keys-only listing — `export` is the only inventory command — so the full
# secret values are fetched to learn their names. They are never persisted: the
# export lives in a single shell local for one shape-check and one jq reduction,
# both in-process, and reach neither disk (no context::set, no temp file) nor a
# log. Scoped to secretPath "/" to match the convention fetch's --path="/".
infisical::_export_secret_keys() {
  local project_id="$1" env="$2" export_json
  export_json="$(infisical::_run export --format=json --projectId="$project_id" --env="$env" --silent)"
  # Guard the CLI's export shape before trusting it: every secret must carry both a
  # key and a value. A silently-incompatible schema (renamed/absent fields) would
  # reduce to an empty key set, reading every convention secret as absent — and
  # could then green-light generating a key we never meant to. Fail loudly rather
  # than guess.
  printf '%s' "$export_json" | jq -e 'all(.[]; has("key") and has("value"))' >/dev/null \
    || lifecycle::fail "infisical: unexpected export shape from the CLI — each secret must carry a 'key' and a 'value'. The installed infisical version may be incompatible."
  printf '%s' "$export_json" | jq -r '.[] | select(.secretPath == "/") | .key'
}

# infisical::fetch REFERENCE — the secrets_manager contract function.
# REFERENCE is either an explicit machinekit-defined compact reference
# (infisical://<projectId>/<env>/<name> — Infisical addresses a secret by
# project + environment + name, not a flat URI like op://) or, when a caller
# has no explicit [secrets.manager_refs] entry for this name, the bare
# logical secret name itself, resolved by convention.
infisical::fetch() {
  local reference="$1"
  case "$reference" in
    infisical://*) infisical::_fetch_explicit "$reference" ;;
    *)             infisical::_fetch_by_convention "$reference" ;;
  esac
}

# infisical::has NAME — true when the manager holds the secret NAME maps to by
# convention: a local membership test against the key set captured at readiness
# (infisical::_load_secret_names), no per-call network. The secrets_manager
# existence contract — it lets secrets::backend_for report a convention-backed
# secret as present only when the manager truly has it. (An explicit infisical://
# reference is a directive, trusted without a lookup — it may address any
# project/env, not just the configured default.)
infisical::has() {
  local key
  key="$(infisical::_convention_key "$1")"
  grep -Fxq -- "$key" <<< "$_INFISICAL_SECRET_NAMES"
}

# infisical::has_reference REFERENCE — true when the explicit infisical:// REFERENCE
# was confirmed to resolve at readiness: a local membership test against the
# verified-references cache, no per-call network. The secrets_manager reference
# existence contract — it lets secrets::backend_for report an explicitly-referenced
# secret as present only when the manager truly holds it, rather than trusting the
# directive blind.
infisical::has_reference() {
  grep -Fxq -- "$1" <<< "$_INFISICAL_VERIFIED_REFERENCES"
}

# Probe each configured explicit reference once and cache the ones that resolve.
# An explicit ref can point at any project/env, so the default-project export
# can't vouch for it — each gets its own `secrets get`. A malformed ref fails
# loudly here (it's user config); a well-formed but absent one is simply left out
# of the cache, so backend_for later reports it missing rather than a false present.
infisical::_verify_explicit_references() {
  local reference
  while IFS= read -r reference; do
    [ -n "$reference" ] || continue
    infisical::_reference_wellformed "$reference" \
      || lifecycle::fail "infisical: malformed reference '$reference' in [secrets.manager_refs] — expected infisical://<projectId>/<env>/<name>."
    if infisical::_fetch_explicit "$reference" >/dev/null 2>&1; then
      _INFISICAL_VERIFIED_REFERENCES+="${_INFISICAL_VERIFIED_REFERENCES:+$'\n'}$reference"
    fi
  done < <(infisical::_configured_references)
}

# The explicit infisical:// references configured in [secrets.manager_refs], one
# per line. That table registers every satisfier's references; this satisfier
# reads only its own scheme, leaving another manager's refs to that manager.
infisical::_configured_references() {
  local refs_json
  refs_json="$(config::get "secrets.manager_refs" 2>/dev/null || true)"
  [ -n "$refs_json" ] || return 0
  printf '%s' "$refs_json" | jq -r 'to_entries[] | .value' | grep '^infisical://' || true
}

# infisical::_reference_wellformed REFERENCE — true when REFERENCE is a complete
# infisical://<projectId>/<env>/<name> (three non-empty, slash-delimited parts;
# name may itself contain slashes). A pure predicate: the callers phrase the
# failure, so it stays reusable between resolve-time and readiness-time checks.
infisical::_reference_wellformed() {
  local without_scheme="${1#infisical://}" rest
  [[ "$without_scheme" == */*/* ]] || return 1
  [ -n "${without_scheme%%/*}" ] || return 1
  rest="${without_scheme#*/}"
  [ -n "${rest%%/*}" ] && [ -n "${rest#*/}" ]
}

infisical::_fetch_explicit() {
  local reference="$1" without_scheme rest project_id env name
  infisical::_reference_wellformed "$reference" \
    || lifecycle::fail "infisical: malformed reference '$reference' — expected infisical://<projectId>/<env>/<name>."
  without_scheme="${reference#infisical://}"
  project_id="${without_scheme%%/*}"
  rest="${without_scheme#*/}"
  env="${rest%%/*}"
  name="${rest#*/}"
  infisical::_get "$project_id" "$env" "$name"
}

infisical::_fetch_by_convention() {
  local name="$1"
  infisical::_get "$(infisical::_default_project_id)" "$(infisical::_environment)" "$(infisical::_convention_key "$name")"
}

# The env-var-style key a bare logical name maps to by convention: slashes to
# underscores, upcased (matching HINDSIGHT_API_* elsewhere) — machinekit's own
# naming, not an Infisical rule. The single source of the mapping, shared by the
# convention fetch and the existence check.
infisical::_convention_key() {
  printf '%s' "$1" | tr '/' '_' | tr '[:lower:]' '[:upper:]'
}

# Run `infisical <args…>` with the access token — when this run holds one, from
# universal auth — exported into its environment only, never argv, where it'd be
# a live bearer credential readable by any local user via ps / /proc/<pid>/cmdline.
# The export is subshell-scoped so it neither leaks into the rest of the run nor
# forces the token onto the command line. A user-auth session carries no token
# here and falls back to the CLI's keyring session. Every authenticated infisical
# call routes through this — the one place the token touches the environment.
infisical::_run() {
  (
    # shellcheck disable=SC2030,SC2031  # export is deliberately subshell-scoped
    if [ -n "$_INFISICAL_TOKEN" ]; then export INFISICAL_TOKEN="$_INFISICAL_TOKEN"; fi
    infisical "$@"
  )
}

# Fetch NAME from the given project/env, plaintext to stdout.
infisical::_get() {
  local project_id="$1" env="$2" name="$3"
  infisical::_run secrets get "$name" --path="/" --env="$env" --projectId="$project_id" --silent --plain
}

# Exchange the machine-identity client id/secret for a short-lived access token.
# Both go through the INFISICAL_UNIVERSAL_AUTH_* environment variables, never
# argv — the client secret is the identity's non-expiring root of trust, and an
# argv element is readable via ps / /proc/<pid>/cmdline by any local user, the
# exact exposure universal auth's headless (possibly multi-user) deployment
# invites. Resolved into locals first so a failed --secret resolution propagates
# under set -e rather than being swallowed by the command substitution.
infisical::_login_universal() {
  local client_id client_secret
  client_id="$(infisical::_client_id)"
  client_secret="$(infisical::_client_secret)"
  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$client_id" \
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$client_secret" \
    infisical login --method=universal-auth --silent --plain
}

infisical::_login_user() {
  infisical::_session_valid && return 0
  logging::info "infisical: no active session — opening your browser to sign in..."
  infisical login
}

infisical::_session_valid() {
  infisical login status >/dev/null 2>&1
}

infisical::_auth_method() {
  config::get "module.infisical.auth_method" --default "universal"
}

infisical::_client_id() {
  config::get "module.infisical.client_id" --default ""
}

# Sensitive — resolved as a bare (non-"config.") context key, the same tier as
# the age key's own bootstrap inputs, never persisted to the store.
infisical::_client_secret() {
  context::get "infisical.client_secret" --secret --required \
    --prompt "Infisical client secret (input hidden):"
}

# The default Infisical project for convention resolution and the readiness
# export. An explicit infisical://<projectId>/… reference overrides it per-secret
# (and can point at a different project), so this is only the fallback.
infisical::_default_project_id() {
  config::get "module.infisical.default_project_id" --default ""
}

infisical::_environment() {
  config::get "module.infisical.environment" --default "prod"
}
