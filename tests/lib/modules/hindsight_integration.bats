#!/usr/bin/env bats
# Tests for lib/modules/hindsight_integration.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/hindsight_integration.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight_integration.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::info
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
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

@test "preflight validates bank configs and runs each integration's own preflight" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  mktest::stub_function hindsight_integration::_validate_bank_configs
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function hindsight_integration::_integrations
  mktest::stub_function hindsight_integration::_is_available "foo"
  mktest::stub_function hindsight_integration::_is_available "bar"
  mktest::stub_function hindsight_integration::foo::preflight
  mktest::stub_function hindsight_integration::bar::preflight
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  hindsight_integration::preflight
  mktest::assert_stub_not_called lifecycle::fail
  # Bank-config validation is an unconditional step of the flow (no branch to skip).
  mktest::assert_stub_called hindsight_integration::_validate_bank_configs
  mktest::assert_stub_called hindsight_integration::foo::preflight
  mktest::assert_stub_called hindsight_integration::bar::preflight
}

@test "preflight returns success when an available integration has no preflight" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_server_url
  STUB_OUTPUT="memory-server" mktest::stub_function hindsight_integration::_server_host
  mktest::stub_function hindsight_integration::_validate_bank_configs
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
  mktest::stub_function hindsight_integration::_validate_bank_configs
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
  mktest::stub_function hindsight_integration::_validate_bank_configs
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

@test "_ensure_configs writes pending configs (tenant announcement moved to postflight)" {
  STUB_OUTPUT="foo" mktest::stub_function hindsight_integration::_integrations
  STUB_RETURN=1 mktest::stub_function hindsight_integration::foo::config_present
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  STUB_OUTPUT="TOK" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="coding" mktest::stub_function hindsight_integration::_bank_id_prefix
  STUB_OUTPUT=$'coding\npersonal' mktest::stub_function hindsight_integration::_auto_recall_banks
  STUB_OUTPUT=$'coding\nmusic' mktest::stub_function hindsight_integration::_tool_use_banks
  mktest::stub_function hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
  hindsight_integration::_ensure_configs
  mktest::assert_stub_called hindsight_integration::foo::write_config "http://memory-server:8888" "TOK" "coding" $'coding\npersonal' $'coding\nmusic'
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

@test "_auto_recall_banks reads the auto_recall_banks array" {
  STUB_OUTPUT=$'coding\npersonal' mktest::stub_function config::get_array \
    "module.hindsight_integration.auto_recall_banks"
  run hindsight_integration::_auto_recall_banks
  [ "${lines[0]}" = "coding" ]
  [ "${lines[1]}" = "personal" ]
}

@test "_auto_recall_banks is empty when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array \
    "module.hindsight_integration.auto_recall_banks"
  run hindsight_integration::_auto_recall_banks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_tool_use_banks reads the tool_use_banks array" {
  STUB_OUTPUT=$'coding\nmusic' mktest::stub_function config::get_array \
    "module.hindsight_integration.tool_use_banks"
  run hindsight_integration::_tool_use_banks
  [ "${lines[0]}" = "coding" ]
  [ "${lines[1]}" = "music" ]
}

@test "_tool_use_banks is empty when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array \
    "module.hindsight_integration.tool_use_banks"
  run hindsight_integration::_tool_use_banks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- post_apply (bank config) ---

@test "post_apply is a no-op when no banks are configured" {
  STUB_RETURN=1 mktest::stub_function hindsight_integration::_has_bank_configs
  mktest::stub_function hindsight_integration::_configure_banks
  run hindsight_integration::post_apply
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called hindsight_integration::_configure_banks
}

@test "post_apply reports without mutating or prompting under dry-run" {
  mktest::stub_function hindsight_integration::_has_bank_configs
  mktest::stub_function input::is_dry_run
  STUB_OUTPUT=$'music\npersonal' mktest::stub_function hindsight_integration::_configured_bank_names
  mktest::stub_function hindsight_integration::_configure_banks_consented
  mktest::stub_function hindsight_integration::_configure_banks
  run hindsight_integration::post_apply
  [ "$status" -eq 0 ]
  # The dry-run summary is the user-facing "what would happen" contract.
  MATCH="would apply Hindsight bank config" mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called hindsight_integration::_configure_banks_consented
  mktest::assert_stub_not_called hindsight_integration::_configure_banks
}

@test "post_apply records the unconsented outcome, warns, and does not mutate when consent is withheld" {
  mktest::stub_function hindsight_integration::_has_bank_configs
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function hindsight_integration::_configure_banks_consented
  mktest::stub_function context::set
  mktest::stub_function hindsight_integration::_configure_banks
  run hindsight_integration::post_apply
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called hindsight_integration::_configure_banks
  mktest::assert_stub_called context::set hindsight_integration.bank_config unconsented
}

@test "post_apply configures the banks when consented" {
  mktest::stub_function hindsight_integration::_has_bank_configs
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_integration::_configure_banks_consented
  mktest::stub_function hindsight_integration::_configure_banks
  hindsight_integration::post_apply
  mktest::assert_stub_called hindsight_integration::_configure_banks
}

# --- _validate_bank_configs ---

@test "_validate_bank_configs hands the configured banks to validate_shape" {
  STUB_OUTPUT='{"music":{"retain_mission":"m"}}' \
    mktest::stub_function hindsight_integration::_bank_configs_json
  mktest::stub_function hindsight::banks::validate_shape
  hindsight_integration::_validate_bank_configs
  mktest::assert_stub_called hindsight::banks::validate_shape '{"music":{"retain_mission":"m"}}'
}

# --- _configure_banks ---

@test "_configure_banks upserts each bank once the fleet is ready" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  mktest::stub_function hindsight::banks::server_reachable "http://memory-server:8888"
  STUB_OUTPUT="tok-123" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="default" mktest::stub_function hindsight_integration::_bank_config_tenant
  STUB_OUTPUT=$'music\npersonal' mktest::stub_function hindsight_integration::_configured_bank_names
  STUB_OUTPUT='{"retain_mission":"m"}' mktest::stub_function hindsight_integration::_bank_config_json "music"
  STUB_OUTPUT='{"disposition_empathy":4}' mktest::stub_function hindsight_integration::_bank_config_json "personal"
  mktest::stub_function hindsight::banks::configure
  mktest::stub_function context::set
  hindsight_integration::_configure_banks
  mktest::assert_stub_called hindsight::banks::configure \
    "http://memory-server:8888" "tok-123" "default" "music" '{"retain_mission":"m"}'
  mktest::assert_stub_called hindsight::banks::configure \
    "http://memory-server:8888" "tok-123" "default" "personal" '{"disposition_empathy":4}'
  mktest::assert_stub_called context::set hindsight_integration.bank_config applied
}

# A bank is stubbed present in the skip tests so the guard is the ONLY thing
# keeping `configure` from firing — otherwise an empty bank list would pass the
# assertion whether or not the guard held.
@test "_configure_banks skips (no reachability probe, no resolve, no mutate) when the tenant key isn't shared" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  mktest::stub_function hindsight_integration::_api_url
  mktest::stub_function hindsight::banks::server_reachable
  mktest::stub_function hindsight::secrets::resolve
  STUB_OUTPUT="music" mktest::stub_function hindsight_integration::_configured_bank_names
  mktest::stub_function hindsight::banks::configure
  mktest::stub_function context::set
  run hindsight_integration::_configure_banks
  [ "$status" -eq 0 ]
  # The soft skip is gated on `provided` alone — it never probes, resolves, or mutates.
  mktest::assert_stub_not_called hindsight::banks::server_reachable
  mktest::assert_stub_not_called hindsight::secrets::resolve
  mktest::assert_stub_not_called hindsight::banks::configure
  mktest::assert_stub_called context::set hindsight_integration.bank_config tenant_unshared
}

@test "_configure_banks skips (no resolve, no mutate) when the server is unreachable" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  STUB_RETURN=1 mktest::stub_function hindsight::banks::server_reachable "http://memory-server:8888"
  mktest::stub_function hindsight::secrets::resolve
  STUB_OUTPUT="music" mktest::stub_function hindsight_integration::_configured_bank_names
  mktest::stub_function hindsight::banks::configure
  mktest::stub_function context::set
  run hindsight_integration::_configure_banks
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called hindsight::secrets::resolve
  mktest::assert_stub_not_called hindsight::banks::configure
  mktest::assert_stub_called context::set hindsight_integration.bank_config unreachable
}

# Regression for the error-masking bug: with the key provided, a resolution
# failure is NOT the "isn't shared yet" soft skip — that warning is reachable
# only via a not-provided key, so it must never fire once `provided` is true.
@test "_configure_banks does not report a resolution failure as the not-shared skip" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="http://memory-server:8888" mktest::stub_function hindsight_integration::_api_url
  mktest::stub_function hindsight::banks::server_reachable "http://memory-server:8888"
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="default" mktest::stub_function hindsight_integration::_bank_config_tenant
  STUB_OUTPUT="music" mktest::stub_function hindsight_integration::_configured_bank_names
  STUB_OUTPUT='{"retain_mission":"m"}' mktest::stub_function hindsight_integration::_bank_config_json "music"
  mktest::stub_function hindsight::banks::configure
  mktest::stub_function context::set
  run hindsight_integration::_configure_banks
  MATCH="isn't shared yet" mktest::assert_stub_not_called logging::warn
}

# --- postflight_info ---

@test "postflight_info reports the wired integrations and the server url" {
  STUB_OUTPUT=$'claude_code\ncodex' mktest::stub_function hindsight_integration::_integrations
  STUB_OUTPUT="http://server:8888" mktest::stub_function hindsight_integration::_api_url
  run hindsight_integration::postflight_info
  [[ "$output" == *"claude_code, codex"* ]]
  [[ "$output" == *"http://server:8888"* ]]
}

@test "postflight_info emits nothing when no integrations are configured" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_integrations
  run hindsight_integration::postflight_info
  [ -z "$output" ]
}

# --- postflight_instructions ---

@test "postflight_instructions surfaces the tenant step on a client that has no shared key and no server" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_RETURN=1 mktest::stub_function hindsight_integration::_hindsight_server_active
  STUB_OUTPUT="hindsight/tenant_api_key" mktest::stub_function hindsight::secrets::name "tenant_api_key"
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_bank_config_outcome
  run hindsight_integration::postflight_instructions
  [[ "$output" == *"hindsight/tenant_api_key"* ]]
}

@test "postflight_instructions defers the tenant step to hindsight_server when it is active" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  mktest::stub_function hindsight_integration::_hindsight_server_active
  STUB_OUTPUT="hindsight/tenant_api_key" mktest::stub_function hindsight::secrets::name "tenant_api_key"
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_bank_config_outcome
  run hindsight_integration::postflight_instructions
  [[ "$output" != *"tenant_api_key"* ]]
}

@test "postflight_instructions surfaces the re-consent step when bank config was unconsented" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="unconsented" mktest::stub_function hindsight_integration::_bank_config_outcome
  run hindsight_integration::postflight_instructions
  [[ "$output" == *"MACHINEKIT_HINDSIGHT_INTEGRATION_CONFIGURE_BANKS=1"* ]]
}

@test "postflight_instructions surfaces the server-up step when bank config was unreachable" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="unreachable" mktest::stub_function hindsight_integration::_bank_config_outcome
  run hindsight_integration::postflight_instructions
  [[ "$output" == *"unreachable"* ]]
}

@test "postflight_instructions emits nothing when the key is shared and bank config applied" {
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_OUTPUT="applied" mktest::stub_function hindsight_integration::_bank_config_outcome
  run hindsight_integration::postflight_instructions
  [ -z "$output" ]
}

# --- _bank_config_outcome / _hindsight_server_active ---

@test "_bank_config_outcome reads the recorded outcome, defaulting to empty" {
  STUB_OUTPUT="applied" mktest::stub_function context::get "hindsight_integration.bank_config" --default ""
  run hindsight_integration::_bank_config_outcome
  [ "$output" = "applied" ]
}

@test "_hindsight_server_active is true when hindsight_server is in the active set" {
  STUB_OUTPUT=$'git\nhindsight_server\ntailscale' mktest::stub_function context::get_array "modules.active"
  run hindsight_integration::_hindsight_server_active
  [ "$status" -eq 0 ]
}

@test "_hindsight_server_active is false when hindsight_server is absent" {
  STUB_OUTPUT=$'git\ntailscale' mktest::stub_function context::get_array "modules.active"
  run hindsight_integration::_hindsight_server_active
  [ "$status" -ne 0 ]
}

# --- bank config readers ---

@test "_bank_configs_json reads the additional_banks subtree via config::get_json, defaulting to {}" {
  STUB_OUTPUT='{"music":{"retain_mission":"m"}}' mktest::stub_function config::get_json \
    "module.hindsight_integration.additional_banks" "{}"
  run hindsight_integration::_bank_configs_json
  [ "$output" = '{"music":{"retain_mission":"m"}}' ]
}

@test "_configured_bank_names lists banks in blueprint order, not sorted" {
  # Keys deliberately non-alphabetical so the test distinguishes keys_unsorted
  # (blueprint order) from keys (sorted would be coding, music, personal).
  STUB_OUTPUT='{"personal":{},"music":{},"coding":{}}' mktest::stub_function hindsight_integration::_bank_configs_json
  run hindsight_integration::_configured_bank_names
  [ "${lines[0]}" = "personal" ]
  [ "${lines[1]}" = "music" ]
  [ "${lines[2]}" = "coding" ]
}

@test "_bank_config_json returns one bank's table verbatim" {
  STUB_OUTPUT='{"music":{"retain_mission":"m"},"personal":{"disposition_empathy":4}}' \
    mktest::stub_function hindsight_integration::_bank_configs_json
  run hindsight_integration::_bank_config_json personal
  [ "$output" = '{"disposition_empathy":4}' ]
}

@test "_has_bank_configs is true when a config exists" {
  STUB_OUTPUT="music" mktest::stub_function hindsight_integration::_configured_bank_names
  hindsight_integration::_has_bank_configs
}

@test "_has_bank_configs is false when none exist" {
  STUB_OUTPUT="" mktest::stub_function hindsight_integration::_configured_bank_names
  run hindsight_integration::_has_bank_configs
  [ "$status" -ne 0 ]
}

# --- _bank_config_tenant ---

@test "_bank_config_tenant reads module.hindsight_integration.tenant, defaulting to 'default'" {
  STUB_OUTPUT="default" mktest::stub_function config::get \
    "module.hindsight_integration.tenant" --default "default"
  run hindsight_integration::_bank_config_tenant
  [ "$output" = "default" ]
}

# --- _configure_banks_consented ---

@test "_configure_banks_consented reads the consent key with a no-consent default" {
  STUB_OUTPUT="true" mktest::stub_function context::get \
    "hindsight_integration.configure_banks" --default false --coerce boolean \
    --prompt "$_HINDSIGHT_INTEGRATION_CONSENT_PROMPT"
  hindsight_integration::_configure_banks_consented
  # The safety contract is the arguments, not just the compare: an unset key must
  # resolve to false (no consent), read from this exact key.
  mktest::assert_stub_called context::get \
    "hindsight_integration.configure_banks" --default false --coerce boolean \
    --prompt "$_HINDSIGHT_INTEGRATION_CONSENT_PROMPT"
}

@test "_configure_banks_consented is false when consent resolves false" {
  STUB_OUTPUT="false" mktest::stub_function context::get \
    "hindsight_integration.configure_banks" --default false --coerce boolean \
    --prompt "$_HINDSIGHT_INTEGRATION_CONSENT_PROMPT"
  run hindsight_integration::_configure_banks_consented
  [ "$status" -ne 0 ]
}
