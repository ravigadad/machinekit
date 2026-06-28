#!/usr/bin/env bats
# Tests for lib/machinekit/secrets.sh — the blueprint secrets-pool inventory.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  unset _MK_SECRETS_LOADED
  # shellcheck source=../../../lib/machinekit/secrets.sh
  source "$MACHINEKIT_DIR/lib/machinekit/secrets.sh"
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
