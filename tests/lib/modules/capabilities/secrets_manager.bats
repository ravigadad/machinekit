#!/usr/bin/env bats
# Tests for lib/modules/capabilities/secrets_manager.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/capabilities/secrets_manager.sh
  source "$MACHINEKIT_DIR/lib/modules/capabilities/secrets_manager.sh"
}

# --- secrets_manager::is_capability ---

@test "is_capability returns 0" {
  secrets_manager::is_capability
}

# --- secrets_manager::fetch ---

@test "fetch dispatches to the active satisfier's fetch" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  infisical::fetch() { printf 'called with %s\n' "$1"; }
  run secrets_manager::fetch "infisical://proj/env/path/name"
  [ "$output" = "called with infisical://proj/env/path/name" ]
}

@test "fetch fails clearly when no secrets-manager satisfier is active" {
  STUB_RETURN=1 mktest::stub_function modules::capability_satisfier "secrets_manager"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets_manager::fetch "some-reference"
  MATCH="no secrets-manager module" mktest::assert_stub_called lifecycle::fail
}

# --- secrets_manager::ensure_ready ---

@test "ensure_ready readies the active satisfier" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  mktest::stub_function infisical::ensure_ready
  secrets_manager::ensure_ready
  mktest::assert_stub_called infisical::ensure_ready
}

@test "ensure_ready is a no-op when no satisfier is active" {
  STUB_RETURN=1 mktest::stub_function modules::capability_satisfier "secrets_manager"
  run secrets_manager::ensure_ready
  [ "$status" -eq 0 ]
}

# --- secrets_manager::has ---

@test "has reflects the active satisfier's true answer" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  mktest::stub_function infisical::has "tailscale/default"
  secrets_manager::has "tailscale/default"
}

@test "has reflects the active satisfier's false answer" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  STUB_RETURN=1 mktest::stub_function infisical::has "tailscale/default"
  run ! secrets_manager::has "tailscale/default"
}

@test "has is false when no satisfier is active" {
  STUB_RETURN=1 mktest::stub_function modules::capability_satisfier "secrets_manager"
  run ! secrets_manager::has "tailscale/default"
}

# --- secrets_manager::has_reference ---

@test "has_reference reflects the active satisfier's true answer" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  mktest::stub_function infisical::has_reference "infisical://p/e/x"
  secrets_manager::has_reference "infisical://p/e/x"
}

@test "has_reference reflects the active satisfier's false answer" {
  STUB_OUTPUT="infisical" mktest::stub_function modules::capability_satisfier "secrets_manager"
  STUB_RETURN=1 mktest::stub_function infisical::has_reference "infisical://p/e/x"
  run ! secrets_manager::has_reference "infisical://p/e/x"
}

@test "has_reference is false when no satisfier is active" {
  STUB_RETURN=1 mktest::stub_function modules::capability_satisfier "secrets_manager"
  run ! secrets_manager::has_reference "infisical://p/e/x"
}

# --- secrets_manager::requires ---

@test "requires fails clearly — there is no default satisfier" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets_manager::requires
  MATCH="no secrets-manager module" mktest::assert_stub_called lifecycle::fail
}

# --- secrets_manager::install ---

@test "install is a no-op" {
  run secrets_manager::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
