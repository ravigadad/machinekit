#!/usr/bin/env bats
# Tests for lib/modules/infisical.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/infisical.sh
  source "$MACHINEKIT_DIR/lib/modules/infisical.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
}

# --- infisical::provides ---

@test "provides declares the secrets_manager capability" {
  run infisical::provides
  [ "$output" = "secrets_manager" ]
}

# --- infisical::ensure_ready ---

@test "ensure_ready installs the CLI, authenticates, caches the secret names, then verifies explicit refs" {
  mktest::stub_function brew::install_formula "infisical" "--override-dry-run"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function infisical::_authenticate
  mktest::stub_function infisical::_load_secret_names
  mktest::stub_function infisical::_verify_explicit_references
  infisical::ensure_ready
  mktest::assert_stub_called_in_order brew::install_formula "infisical" "--override-dry-run"
  mktest::assert_stub_called_in_order infisical::_authenticate
  mktest::assert_stub_called_in_order infisical::_load_secret_names
  mktest::assert_stub_called_in_order infisical::_verify_explicit_references
  mktest::assert_stub_not_called logging::info
}

@test "ensure_ready in dry-run still authenticates and flags it as the only mutation" {
  mktest::stub_function brew::install_formula "infisical" "--override-dry-run"
  mktest::stub_function input::is_dry_run
  mktest::stub_function infisical::_authenticate
  mktest::stub_function infisical::_load_secret_names
  mktest::stub_function infisical::_verify_explicit_references
  infisical::ensure_ready
  mktest::assert_stub_called infisical::_authenticate
  mktest::assert_stub_called infisical::_load_secret_names
  mktest::assert_stub_called infisical::_verify_explicit_references
  MATCH="prerequisite" mktest::assert_stub_called logging::info
}

# --- infisical::_authenticate ---

@test "_authenticate via universal auth populates the access token" {
  STUB_OUTPUT="universal" mktest::stub_function infisical::_auth_method
  STUB_OUTPUT="TOKEN123" mktest::stub_function infisical::_login_universal
  mktest::stub_function infisical::_login_user
  STUB_OUTPUT="MACHINEKIT_INFISICAL_CLIENT_SECRET" mktest::stub_function context::env_var_name "infisical.client_secret"
  infisical::_authenticate
  [ "$_INFISICAL_TOKEN" = "TOKEN123" ]
  mktest::assert_stub_not_called infisical::_login_user
}

@test "_authenticate scrubs the client secret from the environment after a universal-auth login" {
  export MACHINEKIT_INFISICAL_CLIENT_SECRET="root-credential"
  STUB_OUTPUT="universal" mktest::stub_function infisical::_auth_method
  STUB_OUTPUT="TOKEN123" mktest::stub_function infisical::_login_universal
  STUB_OUTPUT="MACHINEKIT_INFISICAL_CLIENT_SECRET" mktest::stub_function context::env_var_name "infisical.client_secret"
  infisical::_authenticate
  [ -z "${MACHINEKIT_INFISICAL_CLIENT_SECRET:-}" ]
}

@test "_authenticate via user auth logs in interactively" {
  STUB_OUTPUT="user" mktest::stub_function infisical::_auth_method
  mktest::stub_function input::is_interactive
  mktest::stub_function infisical::_login_universal
  mktest::stub_function infisical::_login_user
  infisical::_authenticate
  mktest::assert_stub_called infisical::_login_user
  mktest::assert_stub_not_called infisical::_login_universal
}

@test "_authenticate fails for user auth in a non-interactive run, before any login" {
  STUB_OUTPUT="user" mktest::stub_function infisical::_auth_method
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function infisical::_login_user
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! infisical::_authenticate
  MATCH="requires an interactive session" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called infisical::_login_user
}

@test "_authenticate fails on an unrecognized auth_method" {
  STUB_OUTPUT="bogus" mktest::stub_function infisical::_auth_method
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! infisical::_authenticate
  MATCH="auth_method 'bogus'" mktest::assert_stub_called lifecycle::fail
}

# --- infisical::fetch ---

@test "fetch dispatches an infisical:// reference to _fetch_explicit" {
  mktest::stub_function infisical::_fetch_explicit "infisical://proj/prod/tailscale_default"
  mktest::stub_function infisical::_fetch_by_convention
  infisical::fetch "infisical://proj/prod/tailscale_default"
  mktest::assert_stub_called infisical::_fetch_explicit "infisical://proj/prod/tailscale_default"
  mktest::assert_stub_not_called infisical::_fetch_by_convention
}

@test "fetch dispatches a bare name to _fetch_by_convention" {
  mktest::stub_function infisical::_fetch_explicit
  mktest::stub_function infisical::_fetch_by_convention "tailscale/default"
  infisical::fetch "tailscale/default"
  mktest::assert_stub_called infisical::_fetch_by_convention "tailscale/default"
  mktest::assert_stub_not_called infisical::_fetch_explicit
}

# --- infisical::has ---

@test "has is true when the convention key is in the readiness cache" {
  _INFISICAL_SECRET_NAMES=$'OTHER_KEY\nTAILSCALE_DEFAULT'
  STUB_OUTPUT="TAILSCALE_DEFAULT" mktest::stub_function infisical::_convention_key "tailscale/default"
  infisical::has "tailscale/default"
}

@test "has is false when the convention key is absent from the cache" {
  _INFISICAL_SECRET_NAMES=$'OTHER_KEY'
  STUB_OUTPUT="TAILSCALE_DEFAULT" mktest::stub_function infisical::_convention_key "tailscale/default"
  run ! infisical::has "tailscale/default"
}

@test "has is false against an empty cache" {
  _INFISICAL_SECRET_NAMES=""
  STUB_OUTPUT="TAILSCALE_DEFAULT" mktest::stub_function infisical::_convention_key "tailscale/default"
  run ! infisical::has "tailscale/default"
}

@test "has is false when the cache holds only a superstring of the key (whole-line match, not substring)" {
  _INFISICAL_SECRET_NAMES=$'OTHER_KEY\nTAILSCALE_DEFAULT_OLD'
  STUB_OUTPUT="TAILSCALE_DEFAULT" mktest::stub_function infisical::_convention_key "tailscale/default"
  run ! infisical::has "tailscale/default"
}

# --- infisical::has_reference ---

@test "has_reference is true when the reference is in the verified-references cache" {
  _INFISICAL_VERIFIED_REFERENCES=$'infisical://p/e/other\ninfisical://p/e/x'
  infisical::has_reference "infisical://p/e/x"
}

@test "has_reference is false when the reference is absent from the cache" {
  _INFISICAL_VERIFIED_REFERENCES=$'infisical://p/e/other'
  run ! infisical::has_reference "infisical://p/e/x"
}

@test "has_reference is false against an empty cache (nothing verified)" {
  _INFISICAL_VERIFIED_REFERENCES=""
  run ! infisical::has_reference "infisical://p/e/x"
}

# --- infisical::_load_secret_names ---

@test "_load_secret_names caches the exported keys for the default project/env" {
  STUB_OUTPUT="proj-123" mktest::stub_function infisical::_default_project_id
  STUB_OUTPUT="prod" mktest::stub_function infisical::_environment
  STUB_OUTPUT=$'K_ONE\nK_TWO' mktest::stub_function infisical::_export_secret_keys "proj-123" "prod"
  infisical::_load_secret_names
  [ "$_INFISICAL_SECRET_NAMES" = $'K_ONE\nK_TWO' ]
}

@test "_load_secret_names leaves the cache empty and skips the export when no default project is set" {
  STUB_OUTPUT="" mktest::stub_function infisical::_default_project_id
  mktest::stub_function infisical::_export_secret_keys
  infisical::_load_secret_names
  [ -z "$_INFISICAL_SECRET_NAMES" ]
  mktest::assert_stub_not_called infisical::_export_secret_keys
}

# --- infisical::_export_secret_keys ---

@test "_export_secret_keys extracts the root-path keys from the JSON export" {
  STUB_OUTPUT='[{"key":"K_ONE","secretPath":"/","value":"v1"},{"key":"K_TWO","secretPath":"/","value":"v2"}]' \
    mktest::stub_function infisical::_run export --format=json --projectId=proj-123 --env=prod --silent
  run infisical::_export_secret_keys "proj-123" "prod"
  [ "$output" = $'K_ONE\nK_TWO' ]
}

@test "_export_secret_keys excludes secrets nested under a non-root path" {
  STUB_OUTPUT='[{"key":"ROOT_KEY","secretPath":"/","value":"v"},{"key":"NESTED_KEY","secretPath":"/folder","value":"v"}]' \
    mktest::stub_function infisical::_run export --format=json --projectId=proj-123 --env=prod --silent
  run infisical::_export_secret_keys "proj-123" "prod"
  [ "$output" = "ROOT_KEY" ]
}

@test "_export_secret_keys fails when a secret in the export is missing its value (incompatible CLI shape)" {
  STUB_OUTPUT='[{"key":"K_ONE","secretPath":"/","value":"v1"},{"key":"K_TWO","secretPath":"/"}]' \
    mktest::stub_function infisical::_run export --format=json --projectId=proj-123 --env=prod --silent
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! infisical::_export_secret_keys "proj-123" "prod"
  MATCH="unexpected export shape" mktest::assert_stub_called lifecycle::fail
}

@test "_export_secret_keys accepts an empty export (no secrets) without failing the shape check" {
  STUB_OUTPUT='[]' mktest::stub_function infisical::_run export --format=json --projectId=proj-123 --env=prod --silent
  run infisical::_export_secret_keys "proj-123" "prod"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- infisical::_fetch_explicit ---

@test "_fetch_explicit parses projectId/env/name out of the reference and fetches" {
  STUB_OUTPUT="fake-secret-value" mktest::stub_function infisical::_get "proj-123" "prod" "tailscale_default"
  run infisical::_fetch_explicit "infisical://proj-123/prod/tailscale_default"
  [ "$output" = "fake-secret-value" ]
}

@test "_fetch_explicit preserves internal slashes in a multi-segment name" {
  STUB_OUTPUT="fake-secret-value" mktest::stub_function infisical::_get "proj-123" "prod" "tailscale/default"
  run infisical::_fetch_explicit "infisical://proj-123/prod/tailscale/default"
  [ "$output" = "fake-secret-value" ]
}

@test "_fetch_explicit fails on a malformed reference (missing name segment) rather than mis-parsing it" {
  mktest::stub_function infisical::_get
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! infisical::_fetch_explicit "infisical://proj-123/prod"
  MATCH="malformed reference" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called infisical::_get
}

# --- infisical::_reference_wellformed ---

@test "_reference_wellformed accepts a complete projectId/env/name reference" {
  infisical::_reference_wellformed "infisical://proj-123/prod/tailscale_default"
}

@test "_reference_wellformed accepts a multi-segment name" {
  infisical::_reference_wellformed "infisical://proj-123/prod/tailscale/default"
}

@test "_reference_wellformed rejects a reference missing the name segment" {
  run ! infisical::_reference_wellformed "infisical://proj-123/prod"
}

@test "_reference_wellformed rejects a reference with an empty project id" {
  run ! infisical::_reference_wellformed "infisical:///prod/name"
}

@test "_reference_wellformed rejects a reference with an empty env" {
  run ! infisical::_reference_wellformed "infisical://proj-123//name"
}

@test "_reference_wellformed rejects a reference with an empty name" {
  run ! infisical::_reference_wellformed "infisical://proj-123/prod/"
}

# --- infisical::_configured_references ---

@test "_configured_references emits only the infisical:// values from [secrets.manager_refs]" {
  STUB_OUTPUT='{"git_backup/deploy":"infisical://p/e/DEPLOY","other/x":"op://Vault/x","hindsight/key":"infisical://q/e/KEY"}' \
    mktest::stub_function config::get "secrets.manager_refs"
  run infisical::_configured_references
  [ "$output" = $'infisical://p/e/DEPLOY\ninfisical://q/e/KEY' ]
}

@test "_configured_references is empty when no manager refs are configured" {
  STUB_RETURN=1 mktest::stub_function config::get "secrets.manager_refs"
  run infisical::_configured_references
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- infisical::_verify_explicit_references ---

@test "_verify_explicit_references caches the references that resolve and drops the ones that do not" {
  _INFISICAL_VERIFIED_REFERENCES=""
  STUB_OUTPUT=$'infisical://p/e/PRESENT\ninfisical://p/e/ABSENT' \
    mktest::stub_function infisical::_configured_references
  mktest::stub_function infisical::_reference_wellformed
  STUB_OUTPUT="a-value" mktest::stub_function infisical::_fetch_explicit "infisical://p/e/PRESENT"
  STUB_RETURN=1 mktest::stub_function infisical::_fetch_explicit "infisical://p/e/ABSENT"
  infisical::_verify_explicit_references
  [ "$_INFISICAL_VERIFIED_REFERENCES" = "infisical://p/e/PRESENT" ]
}

@test "_verify_explicit_references newline-joins multiple resolving references so each is whole-line matchable" {
  _INFISICAL_VERIFIED_REFERENCES=""
  STUB_OUTPUT=$'infisical://p/e/ONE\ninfisical://p/e/TWO' \
    mktest::stub_function infisical::_configured_references
  mktest::stub_function infisical::_reference_wellformed
  STUB_OUTPUT="v1" mktest::stub_function infisical::_fetch_explicit "infisical://p/e/ONE"
  STUB_OUTPUT="v2" mktest::stub_function infisical::_fetch_explicit "infisical://p/e/TWO"
  infisical::_verify_explicit_references
  [ "$_INFISICAL_VERIFIED_REFERENCES" = $'infisical://p/e/ONE\ninfisical://p/e/TWO' ]
  # A real newline separator is load-bearing: has_reference's whole-line grep must
  # match the second reference, not just the first.
  infisical::has_reference "infisical://p/e/ONE"
  infisical::has_reference "infisical://p/e/TWO"
}

@test "_verify_explicit_references fails loudly on a malformed configured reference" {
  STUB_OUTPUT="infisical://p/e" mktest::stub_function infisical::_configured_references
  STUB_RETURN=1 mktest::stub_function infisical::_reference_wellformed "infisical://p/e"
  mktest::stub_function infisical::_fetch_explicit
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! infisical::_verify_explicit_references
  MATCH="malformed reference" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called infisical::_fetch_explicit
}

# --- infisical::_fetch_by_convention ---

@test "_fetch_by_convention converts the bare name and fetches from the default project/env" {
  STUB_OUTPUT="proj-123" mktest::stub_function infisical::_default_project_id
  STUB_OUTPUT="prod" mktest::stub_function infisical::_environment
  STUB_OUTPUT="TAILSCALE_DEFAULT" mktest::stub_function infisical::_convention_key "tailscale/default"
  STUB_OUTPUT="fake-secret-value" mktest::stub_function infisical::_get "proj-123" "prod" "TAILSCALE_DEFAULT"
  run infisical::_fetch_by_convention "tailscale/default"
  [ "$output" = "fake-secret-value" ]
}

# --- infisical::_convention_key ---

@test "_convention_key upcases and underscore-joins the bare logical name" {
  run infisical::_convention_key "tailscale/default"
  [ "$output" = "TAILSCALE_DEFAULT" ]
}

# --- infisical::_run ---

@test "_run exports the held access token into the CLI environment, never argv" {
  _INFISICAL_TOKEN="TOKEN123"
  local token_file="$BATS_TEST_TMPDIR/run.token" args_file="$BATS_TEST_TMPDIR/run.args"
  infisical() {
    printf '%s' "${INFISICAL_TOKEN:-UNSET}" > "$token_file"
    printf '%s' "$*" > "$args_file"
    printf 'fake-output\n'
  }
  run infisical::_run secrets get NAME --silent
  [ "$output" = "fake-output" ]
  [ "$(cat "$token_file")" = "TOKEN123" ]
  # args pass through verbatim; the token is nowhere among them
  [ "$(cat "$args_file")" = "secrets get NAME --silent" ]
}

@test "_run sets no token env when this run holds no access token (user session)" {
  _INFISICAL_TOKEN=""
  unset INFISICAL_TOKEN
  local token_file="$BATS_TEST_TMPDIR/run.token"
  infisical() { printf '%s' "${INFISICAL_TOKEN:-UNSET}" > "$token_file"; }
  infisical::_run login status
  [ "$(cat "$token_file")" = "UNSET" ]
}

# --- infisical::_get ---

@test "_get fetches via _run with the path/env/project flags and no token on the command line" {
  STUB_OUTPUT="fake-secret-value" \
    mktest::stub_function infisical::_run secrets get NAME --path=/ --env=prod --projectId=proj-123 --silent --plain
  run infisical::_get "proj-123" "prod" "NAME"
  [ "$output" = "fake-secret-value" ]
}

# --- infisical::_login_universal ---

@test "_login_universal supplies client id/secret via env, never on the command line" {
  STUB_OUTPUT="cid-123" mktest::stub_function infisical::_client_id
  STUB_OUTPUT="csecret-456" mktest::stub_function infisical::_client_secret
  local env_file="$BATS_TEST_TMPDIR/infisical.env" args_file="$BATS_TEST_TMPDIR/infisical.args"
  infisical() {
    printf 'id=%s secret=%s' "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}" "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}" > "$env_file"
    printf '%s' "$*" > "$args_file"
    printf 'TOKEN123\n'
  }
  run infisical::_login_universal
  [ "$output" = "TOKEN123" ]
  [ "$(cat "$env_file")" = "id=cid-123 secret=csecret-456" ]
  [ "$(cat "$args_file")" = "login --method=universal-auth --silent --plain" ]
}

# --- infisical::_login_user ---

@test "_login_user does nothing when a session is already valid" {
  mktest::stub_function infisical::_session_valid
  mktest::stub_function infisical
  infisical::_login_user
  mktest::assert_stub_not_called infisical
}

@test "_login_user opens the browser login when no session is valid" {
  STUB_RETURN=1 mktest::stub_function infisical::_session_valid
  mktest::stub_function infisical "login"
  infisical::_login_user
  mktest::assert_stub_called infisical "login"
  mktest::assert_stub_called logging::info
}

# --- infisical::_session_valid ---

@test "_session_valid reflects the infisical login status exit code" {
  mktest::stub_function infisical "login" "status"
  infisical::_session_valid
}

@test "_session_valid is false when no session is authenticated" {
  STUB_RETURN=1 mktest::stub_function infisical "login" "status"
  run ! infisical::_session_valid
}

# --- config accessors ---

@test "_auth_method reads module.infisical.auth_method, defaulting to universal" {
  STUB_OUTPUT="user" mktest::stub_function config::get "module.infisical.auth_method" --default "universal"
  run infisical::_auth_method
  [ "$output" = "user" ]
}

@test "_client_id reads module.infisical.client_id, defaulting to empty" {
  STUB_OUTPUT="cid-123" mktest::stub_function config::get "module.infisical.client_id" --default ""
  run infisical::_client_id
  [ "$output" = "cid-123" ]
}

@test "_client_secret resolves via the hidden-prompt input cascade, never config" {
  STUB_OUTPUT="csecret-456" mktest::stub_function context::get "infisical.client_secret" --secret --required \
    --prompt "Infisical client secret (input hidden):"
  run infisical::_client_secret
  [ "$output" = "csecret-456" ]
}

@test "_default_project_id reads module.infisical.default_project_id, defaulting to empty" {
  STUB_OUTPUT="proj-123" mktest::stub_function config::get "module.infisical.default_project_id" --default ""
  run infisical::_default_project_id
  [ "$output" = "proj-123" ]
}

@test "_environment reads module.infisical.environment, defaulting to prod" {
  STUB_OUTPUT="staging" mktest::stub_function config::get "module.infisical.environment" --default "prod"
  run infisical::_environment
  [ "$output" = "staging" ]
}
