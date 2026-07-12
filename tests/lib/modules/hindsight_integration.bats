#!/usr/bin/env bats
# Tests for lib/modules/hindsight_integration.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/hindsight_integration.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight_integration.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::dry_run
}

# --- requires ---

@test "requires the tenant key's backend plus each active integration's tool module" {
  STUB_OUTPUT=$'hindsight/tenant_api_key\ttrue\ttrue' mktest::stub_function hindsight_integration::declared_secrets
  secrets::declared_backend_requirements() { cat > "$BATS_TEST_TMPDIR/br.stdin"; printf 'age\n'; }
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function hindsight_integration::_integrations
  STUB_OUTPUT="foo_tool" mktest::stub_function hindsight_integration::foo::requires
  STUB_OUTPUT="bar_tool" mktest::stub_function hindsight_integration::bar::requires
  run hindsight_integration::requires
  [ "${lines[0]}" = "age" ]
  [[ "$output" == *"foo_tool"* ]]
  [[ "$output" == *"bar_tool"* ]]
  # The declared tenant-key row is piped to the shared backend classifier.
  [ "$(cat "$BATS_TEST_TMPDIR/br.stdin")" = $'hindsight/tenant_api_key\ttrue\ttrue' ]
}

@test "requires skips an integration that declares no tool dependency" {
  STUB_OUTPUT=$'hindsight/tenant_api_key\ttrue\ttrue' mktest::stub_function hindsight_integration::declared_secrets
  secrets::declared_backend_requirements() { cat > /dev/null; printf 'age\n'; }
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  run hindsight_integration::requires
  # Status 0 is the regression probe: a non-matching declare -F on the last
  # integration leaves the loop (and the function) non-zero without the return 0.
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "age" ]
  [ "${#lines[@]}" -eq 1 ]
}

# --- preflight ---

@test "preflight passes and runs each integration's own preflight" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::_is_available "foo"
  mktest::stub_function hindsight_integration::_is_available "bar"
  mktest::stub_function hindsight_integration::foo::preflight
  mktest::stub_function hindsight_integration::bar::preflight
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  hindsight_integration::preflight
  mktest::assert_stub_not_called lifecycle::fail
  mktest::assert_stub_called hindsight_integration::foo::preflight
  mktest::assert_stub_called hindsight_integration::bar::preflight
}

@test "preflight returns success when an available integration has no preflight" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::_is_available "foo"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run hindsight_integration::preflight
  # foo is available but defines no preflight (declare -F misses); without the
  # return 0 the loop leaves preflight non-zero and the set -e caller exits.
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight passes when only server_url is set" {
  STUB_OUTPUT="https://hindsight.example/api" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::_is_available "foo"
  mktest::stub_function hindsight_integration::foo::preflight
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  hindsight_integration::preflight
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight fails when neither server_url nor server_host is set" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! hindsight_integration::preflight
  MATCH="server_url" mktest::assert_stub_called lifecycle::fail
}

@test "preflight fails on an unknown integration" {
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="bogus" mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::_is_available "bogus"
  STUB_OUTPUT="bar" mktest::stub_function hindsight_integration::_available
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! hindsight_integration::preflight
  MATCH="unknown integration.*bar" mktest::assert_stub_called lifecycle::fail
}

# --- declared_secrets ---

@test "declared_secrets declares the fleet tenant key required and generatable" {
  STUB_OUTPUT="hindsight/tenant_api_key" mktest::stub_function hindsight::secrets::name tenant_api_key
  run hindsight_integration::declared_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'hindsight/tenant_api_key\ttrue\ttrue' ]
}

# --- install ---

@test "install installs each integration, then ensures the configs" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::foo::install
  mktest::stub_function hindsight_integration::bar::install
  mktest::stub_function hindsight_integration::_ensure_configs
  hindsight_integration::install
  mktest::assert_stub_called_in_order hindsight_integration::foo::install
  mktest::assert_stub_called_in_order hindsight_integration::bar::install
  mktest::assert_stub_called_in_order hindsight_integration::_ensure_configs
}

# --- _ensure_configs ---

@test "_ensure_configs does nothing when every integration config is present" {
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::foo::config_present
  mktest::stub_function hindsight::secrets::resolve
  mktest::stub_function hindsight_integration::foo::write_config
  mktest::stub_function hindsight::secrets::announce_generated_tenant
  hindsight_integration::_ensure_configs
  mktest::assert_stub_not_called hindsight::secrets::resolve
  mktest::assert_stub_not_called hindsight_integration::foo::write_config
}

@test "_ensure_configs in dry-run reports without resolving or writing" {
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::foo::config_present
  mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight::secrets::resolve
  mktest::stub_function hindsight_integration::foo::write_config
  hindsight_integration::_ensure_configs
  mktest::assert_stub_not_called hindsight::secrets::resolve
  mktest::assert_stub_not_called hindsight_integration::foo::write_config
  mktest::assert_stub_called logging::dry_run
}

@test "_ensure_configs writes pending configs and announces a generated key" {
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::foo::config_present
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  STUB_OUTPUT="TOK" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="coding" mktest::stub_function hindsight_integration::_bank_id_prefix
  STUB_OUTPUT=$'coding\npersonal' mktest::stub_function hindsight_integration::_auto_recall_banks
  STUB_OUTPUT=$'coding\nmusic' mktest::stub_function hindsight_integration::_tool_use_banks
  mktest::stub_function hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  mktest::stub_function hindsight::secrets::announce_generated_tenant
  hindsight_integration::_ensure_configs
  mktest::assert_stub_called hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  mktest::assert_stub_called hindsight::secrets::announce_generated_tenant
}

@test "_ensure_configs does not announce when the tenant key was provided" {
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::foo::config_present
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  STUB_OUTPUT="TOK" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="coding" mktest::stub_function hindsight_integration::_bank_id_prefix
  mktest::stub_function hindsight_integration::_auto_recall_banks
  mktest::stub_function hindsight_integration::_tool_use_banks
  mktest::stub_function hindsight_integration::foo::write_config
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  mktest::stub_function hindsight::secrets::announce_generated_tenant
  hindsight_integration::_ensure_configs
  mktest::assert_stub_not_called hindsight::secrets::announce_generated_tenant
}

@test "_ensure_configs resolves the token once and shares it across integrations" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::foo::config_present
  STUB_RETURN=1 mktest::stub_function hindsight_integration::bar::config_present
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  STUB_OUTPUT="TOK" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="coding" mktest::stub_function hindsight_integration::_bank_id_prefix
  STUB_OUTPUT=$'coding\npersonal' mktest::stub_function hindsight_integration::_auto_recall_banks
  STUB_OUTPUT=$'coding\nmusic' mktest::stub_function hindsight_integration::_tool_use_banks
  mktest::stub_function hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  mktest::stub_function hindsight_integration::bar::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  hindsight_integration::_ensure_configs
  # Resolved exactly once, and both integrations got the same token.
  TIMES=1 mktest::assert_stub_called hindsight::secrets::resolve "tenant_api_key"
  mktest::assert_stub_called hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  mktest::assert_stub_called hindsight_integration::bar::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
}

# --- _is_available / _available ---

@test "_is_available is true for a sourced integration" {
  hindsight_integration::_is_available claude_code
}

@test "_is_available is false for an unknown integration" {
  run ! hindsight_integration::_is_available not_a_real_integration
}

@test "_available lists the sourced integrations" {
  run hindsight_integration::_available
  [[ "$output" == *"claude_code"* ]]
}

# --- _api_url ---

@test "_api_url uses server_url verbatim when set" {
  STUB_OUTPUT="https://hindsight.example/api" mktest::stub_function hindsight_integration::_server_url
  run hindsight_integration::_api_url
  [ "$output" = "https://hindsight.example/api" ]
}

@test "_api_url composes http from host and port when server_url is unset" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="8888" mktest::stub_function hindsight_integration::_api_port
  run hindsight_integration::_api_url
  [ "$output" = "http://memory-server:8888" ]
}

@test "_api_url prefers server_url when both are set" {
  STUB_OUTPUT="https://hindsight.example/api" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  STUB_OUTPUT="8888" mktest::stub_function hindsight_integration::_api_port
  run hindsight_integration::_api_url
  [ "$output" = "https://hindsight.example/api" ]
}

# --- config readers ---

@test "_integrations reads the module.hindsight_integration.integrations array" {
  STUB_OUTPUT=$'claude_code\ncodex' mktest::stub_function config::get_array \
    "module.hindsight_integration.integrations"
  run hindsight_integration::_integrations
  [ "${lines[0]}" = "claude_code" ]
  [ "${lines[1]}" = "codex" ]
}

@test "_server_host reads module.hindsight_integration.server_host with no default" {
  STUB_OUTPUT="memory-server" mktest::stub_function config::get \
    "module.hindsight_integration.server_host" --default ""
  run hindsight_integration::_server_host
  [ "$output" = "memory-server" ]
}

@test "_server_url reads module.hindsight_integration.server_url with no default" {
  STUB_OUTPUT="https://hindsight.example/api" mktest::stub_function config::get \
    "module.hindsight_integration.server_url" --default ""
  run hindsight_integration::_server_url
  [ "$output" = "https://hindsight.example/api" ]
}

@test "_api_port reads module.hindsight_integration.api_port, defaulting to 8888" {
  STUB_OUTPUT="9000" mktest::stub_function config::get \
    "module.hindsight_integration.api_port" --default "8888"
  run hindsight_integration::_api_port
  [ "$output" = "9000" ]
}

@test "_bank_id_prefix reads module.hindsight_integration.bank_id_prefix, defaulting to coding" {
  STUB_OUTPUT="work" mktest::stub_function config::get \
    "module.hindsight_integration.bank_id_prefix" --default "coding"
  run hindsight_integration::_bank_id_prefix
  [ "$output" = "work" ]
}

@test "_auto_recall_banks reads the additional_banks.auto_recall array" {
  STUB_OUTPUT=$'coding\npersonal' mktest::stub_function config::get_array \
    "module.hindsight_integration.additional_banks.auto_recall"
  run hindsight_integration::_auto_recall_banks
  [ "${lines[0]}" = "coding" ]
  [ "${lines[1]}" = "personal" ]
}

@test "_auto_recall_banks is empty when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array \
    "module.hindsight_integration.additional_banks.auto_recall"
  run hindsight_integration::_auto_recall_banks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_tool_use_banks reads the additional_banks.tool_use array" {
  STUB_OUTPUT=$'coding\nmusic' mktest::stub_function config::get_array \
    "module.hindsight_integration.additional_banks.tool_use"
  run hindsight_integration::_tool_use_banks
  [ "${lines[0]}" = "coding" ]
  [ "${lines[1]}" = "music" ]
}

@test "_tool_use_banks is empty when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array \
    "module.hindsight_integration.additional_banks.tool_use"
  run hindsight_integration::_tool_use_banks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
