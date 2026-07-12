#!/usr/bin/env bash
# secrets cli — the controller actions behind `machinekit secrets`: dispatch a
# parsed command to the read-only `list` (resolve inputs → render) or the `put`
# use-case, after the shared framework bootstrap. The libexec is just flag parsing
# plus a call to dispatch; the orchestration lives here.
[ -n "${_MK_SECRETS_CLI_LOADED:-}" ] && return 0
_MK_SECRETS_CLI_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../secrets.sh"

# secrets::cli::dispatch COMMAND TARGET FROM_FILE — route a parsed invocation to
# its action. TARGET/FROM_FILE are the put positional and --from-file (ignored by
# list).
secrets::cli::dispatch() {
  local command="$1" target="$2" from_file="$3"
  case "$command" in
    list) secrets::cli::list ;;
    put)  secrets::cli::put "$target" "$from_file" ;;
    *)    lifecycle::fail "secrets: unknown command: $command" ;;
  esac
}

# Read-only: bootstrap, resolve inputs (no lock, installs, or staging — none of
# which a listing needs), ready any active secrets manager so its secrets show a
# truthful source (a network loop, possibly an interactive login), then render.
secrets::cli::list() {
  secrets::cli::_bootstrap
  preflight::resolve_inputs
  secrets_manager::ensure_ready
  secrets::assert_age_key_not_pooled
  age::assert_key_source_type
  secrets::render
}

# Bootstrap, then run the put use-case with the parsed target and --from-file.
# Module functions (age::recipient / age::encrypt, the secrets-manager satisfier)
# are already sourced eagerly by lib/machinekit.sh.
secrets::cli::put() {
  local target="$1" from_file="$2"
  secrets::cli::_bootstrap
  secrets::put "$target" "$from_file"
}

# The framework setup both actions share: storage, brew, prerequisites, then the
# input-resolution chain (flags → env → user config) and mode detection.
secrets::cli::_bootstrap() {
  context::init_storage
  brew::bootstrap
  prerequisites::install
  context::seed_from_flags    # requires prerequisites (jq)
  context::load_user_config   # requires prerequisites (toml2json)
  input::detect_mode
}
