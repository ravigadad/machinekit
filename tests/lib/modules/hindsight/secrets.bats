#!/usr/bin/env bats
# Tests for lib/modules/hindsight/secrets.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/hindsight/secrets.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight/secrets.sh"
}

# --- hindsight::secrets::rel ---

@test "rel is the blueprint-relative pool path of the named secret" {
  STUB_OUTPUT="fake-pool/hindsight/tenant_api_key.age" mktest::stub_function secrets::pool_path "hindsight/tenant_api_key.age"
  run hindsight::secrets::rel tenant_api_key
  [ "$output" = "fake-pool/hindsight/tenant_api_key.age" ]
}

# --- hindsight::secrets::path ---

@test "path anchors the pool secret under the blueprints dir" {
  STUB_OUTPUT="/bp" mktest::stub_function blueprints::dir
  STUB_OUTPUT="secrets/hindsight/db_password.age" mktest::stub_function hindsight::secrets::rel db_password
  run hindsight::secrets::path db_password
  [ "$output" = "/bp/secrets/hindsight/db_password.age" ]
}

# --- hindsight::secrets::provided ---

@test "provided is true when the pool secret file exists" {
  local secret; secret=$(mktemp)
  STUB_OUTPUT="$secret" mktest::stub_function hindsight::secrets::path "tenant_api_key"
  hindsight::secrets::provided tenant_api_key
}

@test "provided is false when the pool secret file is absent" {
  STUB_OUTPUT="/nonexistent/db_password.age" mktest::stub_function hindsight::secrets::path "db_password"
  run ! hindsight::secrets::provided db_password
}

# --- hindsight::secrets::resolve ---

@test "resolve decrypts the provided secret when present" {
  mktest::stub_function hindsight::secrets::provided "llm_api_key"
  STUB_OUTPUT="/bp/secrets/hindsight/llm_api_key.age" mktest::stub_function hindsight::secrets::path "llm_api_key"
  STUB_OUTPUT="decrypted-key" mktest::stub_function age::decrypt "/bp/secrets/hindsight/llm_api_key.age"
  STUB_OUTPUT="generated" mktest::stub_function hindsight::secrets::_generate_token
  run hindsight::secrets::resolve llm_api_key
  [ "$output" = "decrypted-key" ]
  mktest::assert_stub_not_called hindsight::secrets::_generate_token
}

@test "resolve generates a token when the secret is not provided" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="fresh-token" mktest::stub_function hindsight::secrets::_generate_token
  mktest::stub_function age::decrypt
  run hindsight::secrets::resolve tenant_api_key
  [ "$output" = "fresh-token" ]
  mktest::assert_stub_not_called age::decrypt
}

# --- hindsight::secrets::_generate_token ---

@test "_generate_token returns a random hex token from openssl" {
  STUB_OUTPUT="abc123" mktest::stub_function openssl "rand" "-hex" "32"
  run hindsight::secrets::_generate_token
  [ "$output" = "abc123" ]
  mktest::assert_stub_called openssl "rand" "-hex" "32"
}

# --- hindsight::secrets::announce_generated_tenant ---

@test "announce_generated_tenant names the file and field, never the value" {
  STUB_OUTPUT="secrets/hindsight/tenant_api_key.age" mktest::stub_function hindsight::secrets::rel "tenant_api_key"
  mktest::stub_function logging::banner
  hindsight::secrets::announce_generated_tenant "/home/u/.config/hindsight/hindsight.env" "HINDSIGHT_API_TENANT_API_KEY"
  MATCH="HINDSIGHT_API_TENANT_API_KEY" mktest::assert_stub_called logging::banner
  MATCH="hindsight.env" mktest::assert_stub_called logging::banner
}
