#!/usr/bin/env bats
# Tests for lib/machinekit/secrets.sh — the blueprint secrets-pool inventory.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  unset _MK_SECRETS_LOADED
  # shellcheck source=../../../lib/machinekit/secrets.sh
  source "$MACHINEKIT_DIR/lib/machinekit/secrets.sh"
}

# --- secrets::pool_path ---

@test "pool_path prefixes a module namespace with the pool root" {
  run secrets::pool_path "tailscale/home.age"
  [ "$status" -eq 0 ]
  [ "$output" = "secrets/tailscale/home.age" ]
}

# --- secrets::_pool_file_path ---

@test "_pool_file_path composes the blueprints dir and the pool path for NAME" {
  STUB_OUTPUT="/bp" mktest::stub_function blueprints::dir
  STUB_OUTPUT="secrets/tailscale/default.age" mktest::stub_function secrets::pool_path "tailscale/default.age"
  run secrets::_pool_file_path "tailscale/default"
  [ "$output" = "/bp/secrets/tailscale/default.age" ]
}

# --- secrets::_manager_ref ---

@test "_manager_ref returns the configured reference for NAME (literal key in the refs table)" {
  STUB_OUTPUT='{"tailscale/default":"op://Personal/tailscale/credential"}' \
    mktest::stub_function config::get "secrets.manager_refs"
  run secrets::_manager_ref "tailscale/default"
  [ "$output" = "op://Personal/tailscale/credential" ]
}

@test "_manager_ref is empty when NAME has no entry in the refs table" {
  STUB_OUTPUT='{"other/name":"op://x"}' mktest::stub_function config::get "secrets.manager_refs"
  run secrets::_manager_ref "tailscale/default"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_manager_ref is empty when no manager_refs table is configured" {
  STUB_RETURN=1 mktest::stub_function config::get "secrets.manager_refs"
  run secrets::_manager_ref "tailscale/default"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_manager_ref resolves a name containing a dot as a literal key (not a split config path)" {
  STUB_OUTPUT='{"git_backup/ssh_keys/deploy.example":"infisical://p/e/DEPLOY"}' \
    mktest::stub_function config::get "secrets.manager_refs"
  run secrets::_manager_ref "git_backup/ssh_keys/deploy.example"
  [ "$output" = "infisical://p/e/DEPLOY" ]
}

# --- secrets::_reference_for ---

@test "_reference_for returns the configured ref when one is set" {
  STUB_OUTPUT="op://Personal/tailscale/credential" mktest::stub_function secrets::_manager_ref "tailscale/default"
  run secrets::_reference_for "tailscale/default"
  [ "$output" = "op://Personal/tailscale/credential" ]
}

@test "_reference_for falls back to the bare name when no ref is configured" {
  STUB_OUTPUT="" mktest::stub_function secrets::_manager_ref "tailscale/default"
  run secrets::_reference_for "tailscale/default"
  [ "$output" = "tailscale/default" ]
}

# --- secrets::_local_signal ---

@test "_local_signal is 'ref' when an explicit manager reference is configured" {
  STUB_OUTPUT="infisical://p/e/x" mktest::stub_function secrets::_manager_ref "tailscale/default"
  mktest::stub_function secrets::_pool_file_path
  run secrets::_local_signal "tailscale/default"
  [ "$output" = "ref" ]
}

@test "_local_signal is 'ref' even when a pool file also exists (an explicit ref overrides the pool)" {
  local pool_file="$BATS_TEST_TMPDIR/tailscale/default.age"
  mkdir -p "$(dirname "$pool_file")"; : > "$pool_file"
  STUB_OUTPUT="infisical://p/e/x" mktest::stub_function secrets::_manager_ref "tailscale/default"
  STUB_OUTPUT="$pool_file" mktest::stub_function secrets::_pool_file_path "tailscale/default"
  run secrets::_local_signal "tailscale/default"
  [ "$output" = "ref" ]
}

@test "_local_signal is 'pool' when no ref is configured but an age-pool file exists" {
  local pool_file="$BATS_TEST_TMPDIR/tailscale/default.age"
  mkdir -p "$(dirname "$pool_file")"; : > "$pool_file"
  STUB_OUTPUT="" mktest::stub_function secrets::_manager_ref "tailscale/default"
  STUB_OUTPUT="$pool_file" mktest::stub_function secrets::_pool_file_path "tailscale/default"
  run secrets::_local_signal "tailscale/default"
  [ "$output" = "pool" ]
}

@test "_local_signal is empty for a convention-backed name (no ref, no pool file)" {
  STUB_OUTPUT="" mktest::stub_function secrets::_manager_ref "tailscale/default"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/no-such-file.age" mktest::stub_function secrets::_pool_file_path "tailscale/default"
  run secrets::_local_signal "tailscale/default"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::backend_for ---

@test "backend_for is manager when the signal is 'ref' and the manager holds the reference" {
  STUB_OUTPUT="ref" mktest::stub_function secrets::_local_signal "tailscale/default"
  STUB_OUTPUT="infisical://p/e/x" mktest::stub_function secrets::_manager_ref "tailscale/default"
  mktest::stub_function modules::capability_active "secrets_manager"
  mktest::stub_function secrets_manager::has_reference "infisical://p/e/x"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "manager" ]
}

@test "backend_for is none when the signal is 'ref' but the manager does NOT hold it — never falls back to pool" {
  STUB_OUTPUT="ref" mktest::stub_function secrets::_local_signal "tailscale/default"
  STUB_OUTPUT="infisical://p/e/missing" mktest::stub_function secrets::_manager_ref "tailscale/default"
  mktest::stub_function modules::capability_active "secrets_manager"
  STUB_RETURN=1 mktest::stub_function secrets_manager::has_reference "infisical://p/e/missing"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "none" ]
}

@test "backend_for is none when the signal is 'ref' but no secrets manager is active" {
  STUB_OUTPUT="ref" mktest::stub_function secrets::_local_signal "tailscale/default"
  STUB_RETURN=1 mktest::stub_function modules::capability_active "secrets_manager"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "none" ]
}

@test "backend_for is pool when the signal is 'pool'" {
  STUB_OUTPUT="pool" mktest::stub_function secrets::_local_signal "tailscale/default"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "pool" ]
}

@test "backend_for is manager (convention) when there is no local signal and the active manager holds the name" {
  STUB_OUTPUT="" mktest::stub_function secrets::_local_signal "tailscale/default"
  mktest::stub_function modules::capability_active "secrets_manager"
  mktest::stub_function secrets_manager::has "tailscale/default"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "manager" ]
}

@test "backend_for is none when there is no local signal and the active manager lacks the name" {
  STUB_OUTPUT="" mktest::stub_function secrets::_local_signal "tailscale/default"
  mktest::stub_function modules::capability_active "secrets_manager"
  STUB_RETURN=1 mktest::stub_function secrets_manager::has "tailscale/default"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "none" ]
}

@test "backend_for is none when there is no local signal and no manager is active" {
  STUB_OUTPUT="" mktest::stub_function secrets::_local_signal "tailscale/default"
  STUB_RETURN=1 mktest::stub_function modules::capability_active "secrets_manager"
  run secrets::backend_for "tailscale/default"
  [ "$output" = "none" ]
}

# --- secrets::assert_age_key_not_pooled ---

@test "assert_age_key_not_pooled fails when a pool file for the age key exists" {
  local pool_file="$BATS_TEST_TMPDIR/age_key.age"; : > "$pool_file"
  STUB_OUTPUT="$pool_file" mktest::stub_function secrets::_pool_file_path "$_MK_SECRETS_AGE_KEY_NAME"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::assert_age_key_not_pooled
  MATCH="age key can't live in the age pool" mktest::assert_stub_called lifecycle::fail
}

@test "assert_age_key_not_pooled is a no-op when no age-key pool file exists" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/absent.age" mktest::stub_function secrets::_pool_file_path "$_MK_SECRETS_AGE_KEY_NAME"
  mktest::stub_function lifecycle::fail
  secrets::assert_age_key_not_pooled
  mktest::assert_stub_not_called lifecycle::fail
}

# --- secrets::backend_requirements ---

@test "backend_requirements requires age for a pool-signal name" {
  STUB_OUTPUT="pool" mktest::stub_function secrets::_local_signal "git_backup/ssh_keys/deploy"
  run secrets::backend_requirements <<< "git_backup/ssh_keys/deploy"
  [ "$output" = "age" ]
}

@test "backend_requirements requires secrets_manager for a ref-signal name" {
  STUB_OUTPUT="ref" mktest::stub_function secrets::_local_signal "git_backup/ssh_keys/deploy"
  run secrets::backend_requirements <<< "git_backup/ssh_keys/deploy"
  [ "$output" = "secrets_manager" ]
}

@test "backend_requirements requires both when names resolve to a mix of signals" {
  STUB_OUTPUT="pool" mktest::stub_function secrets::_local_signal "a/pool"
  STUB_OUTPUT="ref" mktest::stub_function secrets::_local_signal "b/ref"
  run secrets::backend_requirements <<< $'a/pool\nb/ref'
  [ "$output" = $'age\nsecrets_manager' ]
}

@test "backend_requirements emits nothing for a convention-backed name (no local signal)" {
  STUB_OUTPUT="" mktest::stub_function secrets::_local_signal "hindsight/tenant_api_key"
  run secrets::backend_requirements <<< "hindsight/tenant_api_key"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::declared_backend_requirements ---

@test "declared_backend_requirements strips the declared-secret rows to names and classifies their backends" {
  local captured="$BATS_TEST_TMPDIR/stdin"
  secrets::backend_requirements() { cat > "$captured"; printf 'age\n'; }
  run secrets::declared_backend_requirements <<< $'git_backup/ssh_keys/deploy\ttrue\tfalse\ntailscale/default\ttrue\tfalse'
  [ "$output" = "age" ]
  [ "$(cat "$captured")" = $'git_backup/ssh_keys/deploy\ntailscale/default' ]
}

# --- secrets::present ---

@test "present is true when a backend resolves the name" {
  STUB_OUTPUT="pool" mktest::stub_function secrets::backend_for "tailscale/default"
  secrets::present "tailscale/default"
}

@test "present is false when no backend resolves the name" {
  STUB_OUTPUT="none" mktest::stub_function secrets::backend_for "tailscale/default"
  run ! secrets::present "tailscale/default"
}

# --- secrets::resolve ---

@test "resolve fetches from the manager backend, via the resolved reference" {
  STUB_OUTPUT="manager" mktest::stub_function secrets::backend_for "tailscale/default"
  STUB_OUTPUT="op://Personal/tailscale/credential" mktest::stub_function secrets::_reference_for "tailscale/default"
  STUB_OUTPUT="fake-secret-value" mktest::stub_function secrets_manager::fetch "op://Personal/tailscale/credential"
  mktest::stub_function age::decrypt
  run secrets::resolve "tailscale/default"
  [ "$output" = "fake-secret-value" ]
  mktest::assert_stub_not_called age::decrypt
}

@test "resolve decrypts the age-pool file on the pool backend" {
  STUB_OUTPUT="pool" mktest::stub_function secrets::backend_for "tailscale/default"
  STUB_OUTPUT="/bp/secrets/tailscale/default.age" mktest::stub_function secrets::_pool_file_path "tailscale/default"
  STUB_OUTPUT="fake-secret-value" mktest::stub_function age::decrypt "/bp/secrets/tailscale/default.age"
  mktest::stub_function secrets_manager::fetch
  run secrets::resolve "tailscale/default"
  [ "$output" = "fake-secret-value" ]
  mktest::assert_stub_not_called secrets_manager::fetch
}

@test "resolve fails when no backend resolves the name" {
  STUB_OUTPUT="none" mktest::stub_function secrets::backend_for "tailscale/default"
  mktest::stub_function age::decrypt
  mktest::stub_function secrets_manager::fetch
  run ! secrets::resolve "tailscale/default"
  mktest::assert_stub_not_called age::decrypt
  mktest::assert_stub_not_called secrets_manager::fetch
}

# --- secrets::in_pool ---

@test "in_pool lists every .age in the pool, blueprint-relative and sorted" {
  local blueprint_dir; blueprint_dir=$(mktemp -d)
  mkdir -p "$blueprint_dir/secrets/dir"
  : > "$blueprint_dir/secrets/foo.age"
  : > "$blueprint_dir/secrets/dir/bar.age"
  : > "$blueprint_dir/secrets/notes.txt"
  STUB_OUTPUT="$blueprint_dir" mktest::stub_function blueprints::dir
  run secrets::in_pool
  [ "$status" -eq 0 ]
  [ "$output" = $'secrets/dir/bar.age\nsecrets/foo.age' ]
}

@test "in_pool is empty when the pool dir is absent" {
  STUB_OUTPUT="$(mktemp -d)" mktest::stub_function blueprints::dir
  run secrets::in_pool
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::needed ---

@test "needed collects the declared_secrets declarations across active modules" {
  STUB_OUTPUT=$'foo\ttrue\tfalse\nbar\ttrue\ttrue' \
    mktest::stub_function modules::collect declared_secrets
  run secrets::needed
  [ "$status" -eq 0 ]
  [ "$output" = $'foo\ttrue\tfalse\nbar\ttrue\ttrue' ]
}

# --- secrets::inventory ---

@test "inventory reports each declared secret with its resolved backend, in alpha order" {
  STUB_OUTPUT=$'foo\ttrue\tfalse\nbaz\ttrue\ttrue' \
    mktest::stub_function secrets::needed
  STUB_OUTPUT="pool" mktest::stub_function secrets::backend_for "foo"
  STUB_OUTPUT="none" mktest::stub_function secrets::backend_for "baz"
  run secrets::inventory
  [ "$status" -eq 0 ]
  # The declared booleans carry through, joined with the resolved backend
  # (secrets::backend_for's "none" renders as "missing" here).
  [ "$output" = $'baz\ttrue\ttrue\tmissing\nfoo\ttrue\tfalse\tpool' ]
}

@test "inventory reports a manager-backed secret's state as manager" {
  STUB_OUTPUT=$'foo\ttrue\tfalse' mktest::stub_function secrets::needed
  STUB_OUTPUT="manager" mktest::stub_function secrets::backend_for "foo"
  run secrets::inventory
  [ "$status" -eq 0 ]
  [ "$output" = $'foo\ttrue\tfalse\tmanager' ]
}

@test "inventory is empty when no module declares a secret" {
  STUB_OUTPUT="" mktest::stub_function secrets::needed
  mktest::stub_function secrets::backend_for
  run secrets::inventory
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mktest::assert_stub_not_called secrets::backend_for
}

# --- secrets::orphans ---

@test "orphans lists pool secrets no active module declares" {
  STUB_OUTPUT=$'tailscale/default\ttrue\tfalse' mktest::stub_function secrets::needed
  STUB_OUTPUT=$'secrets/tailscale/default.age\nsecrets/stale/leftover.age' \
    mktest::stub_function secrets::in_pool
  run secrets::orphans
  [ "$status" -eq 0 ]
  [ "$output" = "secrets/stale/leftover.age" ]
}

@test "orphans is empty when every pool secret is declared" {
  STUB_OUTPUT=$'tailscale/default\ttrue\tfalse' mktest::stub_function secrets::needed
  STUB_OUTPUT=$'secrets/tailscale/default.age' mktest::stub_function secrets::in_pool
  run secrets::orphans
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::blueprints_dir ---

@test "blueprints_dir uses the explicit override" {
  local override; override=$(mktemp -d)
  STUB_OUTPUT="$override" mktest::stub_function context::get "secrets.blueprints_dir"
  run secrets::blueprints_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$override" && pwd)" ]
}

@test "blueprints_dir falls back to a local blueprints.source" {
  local src; src=$(mktemp -d)
  STUB_RETURN=1 mktest::stub_function context::get "secrets.blueprints_dir"
  STUB_OUTPUT="$src" mktest::stub_function context::get "blueprints.source"
  run secrets::blueprints_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$src" && pwd)" ]
}

@test "blueprints_dir fails when only a remote source is known" {
  STUB_RETURN=1 mktest::stub_function context::get "secrets.blueprints_dir"
  STUB_OUTPUT="https://github.com/me/bp" mktest::stub_function context::get "blueprints.source"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::blueprints_dir
  MATCH="remote" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::dest_path ---

@test "dest_path returns an absolute target unchanged" {
  run secrets::dest_path /tmp/anywhere/secret.age
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/anywhere/secret.age" ]
}

@test "dest_path resolves a relative target against the working tree" {
  STUB_OUTPUT="/work/bp" mktest::stub_function secrets::blueprints_dir
  run secrets::dest_path secrets/hindsight/llm_api_key.age
  [ "$status" -eq 0 ]
  [ "$output" = "/work/bp/secrets/hindsight/llm_api_key.age" ]
}

# --- secrets::place ---

@test "place encrypts stdin to the recipient and writes the dest file" {
  local dest="$BATS_TEST_TMPDIR/pool/secrets/x.age"
  STUB_OUTPUT="CIPHERTEXT" mktest::stub_function age::encrypt "age1fakepubkey"
  secrets::place age1fakepubkey "$dest" <<< "plaintext"
  [ -f "$dest" ]
  [ "$(cat "$dest")" = "CIPHERTEXT" ]
  mktest::assert_stub_called age::encrypt "age1fakepubkey"
}

@test "place leaves an existing dest untouched and no temp behind when encryption fails" {
  local dest="$BATS_TEST_TMPDIR/pool/secret.age"
  mkdir -p "$(dirname "$dest")"; printf 'OLD' > "$dest"
  STUB_RETURN=1 mktest::stub_function age::encrypt "age1fakepubkey"
  run ! secrets::place age1fakepubkey "$dest" <<< "plaintext"
  [ "$(cat "$dest")" = "OLD" ]
  # The temp+rename's reason for being: a failed encrypt leaves no junk in the pool.
  [ "$(find "$(dirname "$dest")" -name '.mk-secret.*' | wc -l)" -eq 0 ]
}

# --- secrets::place_file ---

@test "place_file copies the source verbatim to the dest, creating parents" {
  local src="$BATS_TEST_TMPDIR/src.age" dest="$BATS_TEST_TMPDIR/pool/secrets/x.age"
  printf 'CIPHERTEXT-BYTES' > "$src"
  secrets::place_file "$src" "$dest"
  [ -f "$dest" ]
  [ "$(cat "$dest")" = "CIPHERTEXT-BYTES" ]
}

@test "place_file leaves an existing dest untouched and no temp behind when the copy fails" {
  local dest="$BATS_TEST_TMPDIR/pool/secret.age"
  mkdir -p "$(dirname "$dest")"; printf 'OLD' > "$dest"
  run ! secrets::place_file "$BATS_TEST_TMPDIR/no-such-src" "$dest"
  [ "$(cat "$dest")" = "OLD" ]
  [ "$(find "$(dirname "$dest")" -name '.mk-secret.*' | wc -l)" -eq 0 ]
}

# --- secrets::install_secret_file ---

@test "install_secret_file writes the producer's output to the dest with 600 permissions" {
  local dest="$BATS_TEST_TMPDIR/keys/id"
  mkdir -p "$(dirname "$dest")"
  secrets::install_secret_file "$dest" printf 'SECRET-VALUE'
  [ "$(cat "$dest")" = "SECRET-VALUE" ]
  [ "$(mktest::file_mode "$dest")" = "600" ]
}

@test "install_secret_file fails and leaves no dest or temp when the producer yields nothing" {
  local dest="$BATS_TEST_TMPDIR/keys/id"
  mkdir -p "$(dirname "$dest")"
  run ! secrets::install_secret_file "$dest" true
  [ ! -e "$dest" ]
  [ "$(find "$(dirname "$dest")" -name 'id.*' | wc -l)" -eq 0 ]
}

@test "install_secret_file fails and never truncates an existing dest when the producer fails" {
  local dest="$BATS_TEST_TMPDIR/keys/id"
  mkdir -p "$(dirname "$dest")"; printf 'ORIGINAL' > "$dest"
  run ! secrets::install_secret_file "$dest" false
  [ "$(cat "$dest")" = "ORIGINAL" ]
  [ "$(find "$(dirname "$dest")" -name 'id.*' | wc -l)" -eq 0 ]
}
