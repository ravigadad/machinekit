#!/usr/bin/env bats
# Tests for lib/modules/hindsight_integration/claude_code.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/hindsight_integration/claude_code.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight_integration/claude_code.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
}

# --- requires ---

@test "requires declares the claude_code dependency" {
  run hindsight_integration::claude_code::requires
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude_code" ]
}

# --- install ---

@test "install in dry-run reports and touches nothing" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_integration::claude_code::_add_marketplace
  mktest::stub_function claude
  hindsight_integration::claude_code::install
  mktest::assert_stub_not_called hindsight_integration::claude_code::_add_marketplace
  mktest::assert_stub_not_called claude
  mktest::assert_stub_called logging::dry_run
}

@test "install adds the marketplace and installs the plugin when absent" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_integration::claude_code::_add_marketplace
  STUB_RETURN=1 mktest::stub_function hindsight_integration::claude_code::_plugin_installed
  mktest::stub_function claude "plugin" "install" "hindsight-memory"
  hindsight_integration::claude_code::install
  mktest::assert_stub_called_in_order hindsight_integration::claude_code::_add_marketplace
  mktest::assert_stub_called claude "plugin" "install" "hindsight-memory"
}

@test "install skips the plugin install when already present" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_integration::claude_code::_add_marketplace
  mktest::stub_function hindsight_integration::claude_code::_plugin_installed
  mktest::stub_function claude
  hindsight_integration::claude_code::install
  mktest::assert_stub_not_called claude "plugin" "install" "hindsight-memory"
}

# --- config_present ---

@test "config_present is true when the config file exists" {
  local cfg; cfg=$(mktemp)
  STUB_OUTPUT="$cfg" mktest::stub_function hindsight_integration::claude_code::_config_path
  hindsight_integration::claude_code::config_present
}

@test "config_present is false when the config file is absent" {
  STUB_OUTPUT="/nonexistent/claude-code.json" mktest::stub_function hindsight_integration::claude_code::_config_path
  run ! hindsight_integration::claude_code::config_present
}

# --- write_config ---

@test "write_config writes a 600 json with the connection and bank settings" {
  local dest; dest="$(mktemp -d)/sub/claude-code.json"
  STUB_OUTPUT="$dest" mktest::stub_function hindsight_integration::claude_code::_config_path
  mktest::stub_function hindsight_integration::claude_code::_register_mcp_servers
  hindsight_integration::claude_code::write_config "http://memory-server:8888" "tok123" "work" $'coding\npersonal' $'coding\nmusic'
  [ "$(mktest::file_mode "$dest")" = "600" ]
  [ "$(jq -r '.hindsightApiUrl' "$dest")" = "http://memory-server:8888" ]
  [ "$(jq -r '.hindsightApiToken' "$dest")" = "tok123" ]
  [ "$(jq -r '.bankIdPrefix' "$dest")" = "work" ]
  [ "$(jq -r '.dynamicBankId' "$dest")" = "true" ]
  [ "$(jq -c '.dynamicBankGranularity' "$dest")" = '["project"]' ]
  [ "$(jq -c '.recallAdditionalBanks' "$dest")" = '["coding","personal"]' ]
  mktest::assert_stub_called hindsight_integration::claude_code::_register_mcp_servers "http://memory-server:8888" "tok123" $'coding\nmusic'
}

@test "write_config emits an empty recallAdditionalBanks when none are configured" {
  local dest; dest="$(mktemp -d)/sub/claude-code.json"
  STUB_OUTPUT="$dest" mktest::stub_function hindsight_integration::claude_code::_config_path
  mktest::stub_function hindsight_integration::claude_code::_register_mcp_servers
  hindsight_integration::claude_code::write_config "http://memory-server:8888" "tok123" "coding" "" ""
  [ "$(jq -c '.recallAdditionalBanks' "$dest")" = '[]' ]
}

# --- _register_mcp_servers ---

@test "_register_mcp_servers adds a server for a missing tools bank" {
  STUB_RETURN=1 mktest::stub_function hindsight_integration::claude_code::_mcp_server_present "coding"
  mktest::stub_function claude
  hindsight_integration::claude_code::_register_mcp_servers "http://memory-server:8888" "tok" "coding"
  mktest::assert_stub_called claude "mcp" "add" "-s" "user" "-t" "http" "hindsight-coding" "http://memory-server:8888/mcp/coding/" "--header" "Authorization: Bearer tok"
}

@test "_register_mcp_servers skips a tools bank already registered" {
  mktest::stub_function hindsight_integration::claude_code::_mcp_server_present "coding"
  mktest::stub_function claude
  hindsight_integration::claude_code::_register_mcp_servers "http://memory-server:8888" "tok" "coding"
  mktest::assert_stub_not_called claude
}

@test "_register_mcp_servers does nothing when there are no tools banks" {
  mktest::stub_function claude
  hindsight_integration::claude_code::_register_mcp_servers "http://memory-server:8888" "tok" ""
  mktest::assert_stub_not_called claude
}

@test "_register_mcp_servers adds each missing bank in a multi-line list" {
  STUB_RETURN=1 mktest::stub_function hindsight_integration::claude_code::_mcp_server_present "coding"
  STUB_RETURN=1 mktest::stub_function hindsight_integration::claude_code::_mcp_server_present "personal"
  mktest::stub_function claude
  hindsight_integration::claude_code::_register_mcp_servers "http://memory-server:8888" "tok" $'coding\npersonal'
  mktest::assert_stub_called claude "mcp" "add" "-s" "user" "-t" "http" "hindsight-coding" "http://memory-server:8888/mcp/coding/" "--header" "Authorization: Bearer tok"
  mktest::assert_stub_called claude "mcp" "add" "-s" "user" "-t" "http" "hindsight-personal" "http://memory-server:8888/mcp/personal/" "--header" "Authorization: Bearer tok"
}

# --- _mcp_server_present ---

@test "_mcp_server_present is true when claude mcp list shows the server" {
  STUB_OUTPUT="hindsight-coding  http://memory-server:8888/mcp/coding/" mktest::stub_function claude "mcp" "list"
  hindsight_integration::claude_code::_mcp_server_present "coding"
}

@test "_mcp_server_present is false when the server is absent" {
  STUB_OUTPUT="some-other-server  http://example" mktest::stub_function claude "mcp" "list"
  run ! hindsight_integration::claude_code::_mcp_server_present "coding"
}

# --- _config_path ---

@test "_config_path points at the plugin config under HOME" {
  run hindsight_integration::claude_code::_config_path
  [ "$output" = "$HOME/.hindsight/claude-code.json" ]
}
