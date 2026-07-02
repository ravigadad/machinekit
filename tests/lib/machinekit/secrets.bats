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

@test "needed collects the pool_secrets declarations across active modules" {
  STUB_OUTPUT=$'foo\ttrue\tfalse\nbar\ttrue\ttrue' \
    mktest::stub_function modules::collect pool_secrets
  run secrets::needed
  [ "$status" -eq 0 ]
  [ "$output" = $'foo\ttrue\tfalse\nbar\ttrue\ttrue' ]
}

# --- secrets::inventory ---

@test "inventory reports each declared secret with its pool presence, in alpha order" {
  STUB_OUTPUT=$'foo\ttrue\tfalse\nbaz\ttrue\ttrue' \
    mktest::stub_function secrets::needed
  STUB_OUTPUT=$'foo\nbar' \
    mktest::stub_function secrets::in_pool
  run secrets::inventory
  [ "$status" -eq 0 ]
  # The declared booleans carry through, joined with provided/missing. The
  # pool-only tailscale secret is an orphan, not declared here.
  [ "$output" = $'baz\ttrue\ttrue\tmissing\nfoo\ttrue\tfalse\tprovided' ]
}

@test "inventory is empty when no module declares a secret" {
  STUB_OUTPUT="" mktest::stub_function secrets::needed
  STUB_OUTPUT=$'foo' mktest::stub_function secrets::in_pool
  run secrets::inventory
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::orphans ---

@test "orphans lists pool secrets no active module declares" {
  STUB_OUTPUT=$'foo\ttrue\tfalse' mktest::stub_function secrets::needed
  STUB_OUTPUT=$'foo\nbar\nbaz' \
    mktest::stub_function secrets::in_pool
  run secrets::orphans
  [ "$status" -eq 0 ]
  [ "$output" = $'bar\nbaz' ]
}

@test "orphans is empty when every pool secret is declared" {
  STUB_OUTPUT=$'foo\ttrue\tfalse' mktest::stub_function secrets::needed
  STUB_OUTPUT=$'foo' mktest::stub_function secrets::in_pool
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
