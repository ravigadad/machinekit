#!/usr/bin/env bats
# Tests for lib/modules/hindsight/secrets.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/hindsight/secrets.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight/secrets.sh"
}

# --- hindsight::secrets::name ---

@test "name is the bare logical secret name for the given secret" {
  run hindsight::secrets::name tenant_api_key
  [ "$output" = "hindsight/tenant_api_key" ]
}

# --- hindsight::secrets::provided ---

@test "provided is true when a backend resolves the secret" {
  STUB_OUTPUT="hindsight/tenant_api_key" mktest::stub_function hindsight::secrets::name "tenant_api_key"
  mktest::stub_function secrets::present "hindsight/tenant_api_key"
  hindsight::secrets::provided tenant_api_key
}

@test "provided is false when no backend resolves the secret" {
  STUB_OUTPUT="hindsight/db_password" mktest::stub_function hindsight::secrets::name "db_password"
  STUB_RETURN=1 mktest::stub_function secrets::present "hindsight/db_password"
  run ! hindsight::secrets::provided db_password
}

# --- hindsight::secrets::resolve ---

@test "resolve fetches the provided secret when present" {
  mktest::stub_function hindsight::secrets::provided "llm_api_key"
  STUB_OUTPUT="hindsight/llm_api_key" mktest::stub_function hindsight::secrets::name "llm_api_key"
  STUB_OUTPUT="fetched-key" mktest::stub_function secrets::resolve "hindsight/llm_api_key"
  STUB_OUTPUT="generated" mktest::stub_function hindsight::secrets::_generate_token
  run hindsight::secrets::resolve llm_api_key
  [ "$output" = "fetched-key" ]
  mktest::assert_stub_not_called hindsight::secrets::_generate_token
}

@test "resolve generates a token when the secret is not provided" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="fresh-token" mktest::stub_function hindsight::secrets::_generate_token
  mktest::stub_function secrets::resolve
  run hindsight::secrets::resolve tenant_api_key
  [ "$output" = "fresh-token" ]
  mktest::assert_stub_not_called secrets::resolve
}

# --- hindsight::secrets::_generate_token ---

@test "_generate_token returns a random hex token from openssl" {
  STUB_OUTPUT="abc123" mktest::stub_function openssl "rand" "-hex" "32"
  run hindsight::secrets::_generate_token
  [ "$output" = "abc123" ]
  mktest::assert_stub_called openssl "rand" "-hex" "32"
}
