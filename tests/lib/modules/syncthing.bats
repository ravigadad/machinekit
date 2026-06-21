#!/usr/bin/env bats
# Tests for lib/modules/syncthing.sh
#
# The external `syncthing`-CLI seam (_generate, _start, _wait_ready, _cli_*) is
# stubbed; config parsing/validation runs real jq over obviously-fake JSON.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/syncthing.sh
  source "$MACHINEKIT_DIR/lib/modules/syncthing.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::banner
}

# --- preflight ---

@test "preflight validates folders, ignores, and peers when configured" {
  STUB_OUTPUT='[{"id":"f","path":"/p"}]' mktest::stub_function syncthing::_folders
  STUB_OUTPUT='[{"device_id":"DEV"}]' mktest::stub_function syncthing::_peers
  mktest::stub_function syncthing::_validate_folders
  mktest::stub_function syncthing::_validate_ignores
  mktest::stub_function syncthing::_validate_peers
  mktest::stub_function syncthing::_discovery_options
  syncthing::preflight
  mktest::assert_stub_called syncthing::_validate_folders '[{"id":"f","path":"/p"}]'
  mktest::assert_stub_called syncthing::_validate_ignores '[{"id":"f","path":"/p"}]'
  mktest::assert_stub_called syncthing::_validate_peers '[{"device_id":"DEV"}]'
}

@test "preflight skips validation when nothing is configured" {
  mktest::stub_function syncthing::_folders
  mktest::stub_function syncthing::_peers
  mktest::stub_function syncthing::_validate_folders
  mktest::stub_function syncthing::_validate_ignores
  mktest::stub_function syncthing::_validate_peers
  mktest::stub_function syncthing::_discovery_options
  run syncthing::preflight
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called syncthing::_validate_folders
  mktest::assert_stub_not_called syncthing::_validate_ignores
  mktest::assert_stub_not_called syncthing::_validate_peers
}

@test "preflight rejects an unknown discovery posture" {
  mktest::stub_function syncthing::_folders
  mktest::stub_function syncthing::_peers
  STUB_EXIT=1 mktest::stub_function syncthing::_discovery_options
  run ! syncthing::preflight
}

# --- install (orchestration) ---

@test "install installs the formula then stops in dry-run" {
  mktest::stub_function brew::install_formula syncthing
  mktest::stub_function input::is_dry_run
  mktest::stub_function syncthing::_ensure_identity
  mktest::stub_function syncthing::_announce_identity
  mktest::stub_function syncthing::_start
  mktest::stub_function syncthing::_ensure_folders
  mktest::stub_function syncthing::_wait_ready
  mktest::stub_function syncthing::_apply_discovery
  syncthing::install
  mktest::assert_stub_called brew::install_formula syncthing
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called syncthing::_ensure_identity
  mktest::assert_stub_not_called syncthing::_announce_identity
  mktest::assert_stub_not_called syncthing::_start
  mktest::assert_stub_not_called syncthing::_ensure_folders
  mktest::assert_stub_not_called syncthing::_wait_ready
  mktest::assert_stub_not_called syncthing::_apply_discovery
}

@test "install runs the setup steps in order, then joins and shares the joined devices" {
  mktest::stub_function brew::install_formula syncthing
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function syncthing::_ensure_identity
  mktest::stub_function syncthing::_announce_identity
  mktest::stub_function syncthing::_start
  mktest::stub_function syncthing::_wait_ready
  mktest::stub_function syncthing::_apply_discovery
  mktest::stub_function syncthing::_join_consented
  STUB_OUTPUT=$'DEV1\nDEV2' mktest::stub_function syncthing::_join
  mktest::stub_function syncthing::_ensure_folders
  syncthing::install
  mktest::assert_stub_called_in_order brew::install_formula syncthing
  mktest::assert_stub_called_in_order syncthing::_ensure_identity
  mktest::assert_stub_called_in_order syncthing::_announce_identity
  mktest::assert_stub_called_in_order syncthing::_start
  mktest::assert_stub_called_in_order syncthing::_wait_ready
  mktest::assert_stub_called_in_order syncthing::_apply_discovery
  mktest::assert_stub_called_in_order syncthing::_join_consented
  mktest::assert_stub_called_in_order syncthing::_join
  mktest::assert_stub_called_in_order syncthing::_ensure_folders $'DEV1\nDEV2'
}

@test "install warns and shares nothing when the join is declined" {
  mktest::stub_function brew::install_formula syncthing
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function syncthing::_ensure_identity
  mktest::stub_function syncthing::_announce_identity
  mktest::stub_function syncthing::_start
  mktest::stub_function syncthing::_wait_ready
  mktest::stub_function syncthing::_apply_discovery
  STUB_RETURN=1 mktest::stub_function syncthing::_join_consented
  mktest::stub_function syncthing::_join
  mktest::stub_function syncthing::_ensure_folders
  syncthing::install
  mktest::assert_stub_called_in_order syncthing::_apply_discovery
  mktest::assert_stub_called_in_order syncthing::_join_consented
  mktest::assert_stub_not_called syncthing::_join
  MATCH="not consented" mktest::assert_stub_called logging::warn
  mktest::assert_stub_called_in_order syncthing::_ensure_folders ""
}

# --- _validate_folders / _validate_peers (real jq) ---

@test "_validate_folders passes a well-formed list" {
  run syncthing::_validate_folders '[{"id":"agents","path":"~/.agents"}]'
  [ "$status" -eq 0 ]
}

@test "_validate_folders fails an entry missing an id" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_validate_folders '[{"path":"/p"}]'
  MATCH="id and a path" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_folders fails an entry missing a path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_validate_folders '[{"id":"agents"}]'
  MATCH="id and a path" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_folders fails an entry with an empty path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_validate_folders '[{"id":"agents","path":""}]'
  mktest::assert_stub_called lifecycle::fail
}

@test "_validate_peers passes a well-formed list" {
  run syncthing::_validate_peers '[{"device_id":"DEV-ABC","address":"tcp://host:22000"}]'
  [ "$status" -eq 0 ]
}

@test "_validate_peers fails an entry missing a device_id" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_validate_peers '[{"name":"server"}]'
  MATCH="device_id" mktest::assert_stub_called lifecycle::fail
}

# --- _validate_ignores (real jq) ---

@test "_validate_ignores passes the common defaults-on, no-patterns folder" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  syncthing::_validate_ignores '[{"id":"agents","path":"/p"}]'
  mktest::assert_stub_not_called lifecycle::fail
  mktest::assert_stub_not_called logging::warn
}

@test "_validate_ignores passes an opt-out folder with no patterns" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  syncthing::_validate_ignores '[{"id":"agents","path":"/p","manage_stignore":false}]'
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_ignores fails an opt-out folder that still lists ignore_patterns" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_validate_ignores '[{"id":"agents","path":"/p","manage_stignore":false,"ignore_patterns":["x"]}]'
  MATCH="manage_stignore = false" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_ignores warns on the all-empty no-op folder" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  syncthing::_validate_ignores '[{"id":"agents","path":"/p","add_default_ignores":false}]'
  mktest::assert_stub_not_called lifecycle::fail
  MATCH="empty managed block" mktest::assert_stub_called logging::warn
}

# --- _ensure_identity ---

@test "_ensure_identity generates an identity when none exists" {
  STUB_RETURN=1 mktest::stub_function syncthing::_identity_exists
  mktest::stub_function syncthing::_generate
  syncthing::_ensure_identity
  mktest::assert_stub_called syncthing::_generate
}

@test "_ensure_identity leaves an existing identity untouched" {
  mktest::stub_function syncthing::_identity_exists
  mktest::stub_function syncthing::_generate
  syncthing::_ensure_identity
  mktest::assert_stub_not_called syncthing::_generate
}

# --- _announce_identity ---

@test "_announce_identity tells the hub operator to share its id with clients" {
  STUB_OUTPUT="HUB-ID" mktest::stub_function syncthing::_own_device_id
  mktest::stub_function syncthing::_is_hub
  syncthing::_announce_identity
  MATCH="Put it in" mktest::assert_stub_called logging::banner
}

@test "_announce_identity tells a client its id will be discovered by the hub" {
  STUB_OUTPUT="CLIENT-ID" mktest::stub_function syncthing::_own_device_id
  STUB_RETURN=1 mktest::stub_function syncthing::_is_hub
  syncthing::_announce_identity
  MATCH="discovers it" mktest::assert_stub_called logging::banner
}

# --- _ensure_folders (orchestrator: iterates, delegates per folder) ---

@test "_ensure_folders runs each configured folder through _ensure_folder with the share list" {
  STUB_OUTPUT='[{"id":"a","path":"/pa"},{"id":"b","path":"/pb"}]' mktest::stub_function syncthing::_folders
  mktest::stub_function syncthing::_ensure_folder
  syncthing::_ensure_folders "DEV1 DEV2"
  mktest::assert_stub_called syncthing::_ensure_folder '{"id":"a","path":"/pa"}' "DEV1 DEV2"
  mktest::assert_stub_called syncthing::_ensure_folder '{"id":"b","path":"/pb"}' "DEV1 DEV2"
}

@test "_ensure_folders is a no-op when no folders are configured" {
  mktest::stub_function syncthing::_folders
  mktest::stub_function syncthing::_ensure_folder
  syncthing::_ensure_folders ""
  mktest::assert_stub_not_called syncthing::_ensure_folder
}

# --- _ensure_folder (member: per-folder logic; real mkdir, stubbed collaborators) ---

@test "_ensure_folder creates the dir, reconciles its stignore, and upserts it shared with the devices" {
  local path="$BATS_TEST_TMPDIR/agents"
  mktest::stub_function syncthing::_apply_stignore "{\"id\":\"agents\",\"path\":\"$path\"}" "$path"
  mktest::stub_function syncthing::_cli_ensure_folder "agents" "$path" "DEV1 DEV2"
  syncthing::_ensure_folder "{\"id\":\"agents\",\"path\":\"$path\"}" "DEV1 DEV2"
  [ -d "$path" ]
  mktest::assert_stub_called syncthing::_apply_stignore "{\"id\":\"agents\",\"path\":\"$path\"}" "$path"
  mktest::assert_stub_called syncthing::_cli_ensure_folder "agents" "$path" "DEV1 DEV2"
}

@test "_ensure_folder expands a leading ~ in the path" {
  HOME="$BATS_TEST_TMPDIR"
  mktest::stub_function syncthing::_apply_stignore
  mktest::stub_function syncthing::_cli_ensure_folder "agents" "$HOME/agents" ""
  syncthing::_ensure_folder '{"id":"agents","path":"~/agents"}' ""
  [ -d "$HOME/agents" ]
  mktest::assert_stub_called syncthing::_cli_ensure_folder "agents" "$HOME/agents" ""
}

# --- _apply_stignore / _stignore_patterns / _default_ignores ---

@test "_apply_stignore pipes the folder's patterns into managed_block::ensure for its .stignore" {
  local dir="$BATS_TEST_TMPDIR/agents"
  STUB_OUTPUT=$'a\nb' mktest::stub_function syncthing::_stignore_patterns '{"id":"agents","path":"x"}'
  # Hand-rolled stub: mktest records args but not stdin, and the pipe is the contract.
  managed_block::ensure() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/ensure.args"
    cat > "$BATS_TEST_TMPDIR/ensure.stdin"
  }
  syncthing::_apply_stignore '{"id":"agents","path":"x"}' "$dir"
  [ "$(cat "$BATS_TEST_TMPDIR/ensure.args")" = "$(printf '%s\n//' "$dir/.stignore")" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ensure.stdin")" = "$(printf 'a\nb')" ]
}

@test "_apply_stignore leaves the file alone when manage_stignore is false" {
  mktest::stub_function managed_block::ensure
  syncthing::_apply_stignore '{"id":"agents","path":"x","manage_stignore":false}' "$BATS_TEST_TMPDIR/agents"
  mktest::assert_stub_not_called managed_block::ensure
}

@test "_stignore_patterns emits user patterns before defaults" {
  run syncthing::_stignore_patterns '{"ignore_patterns":["custom1","custom2"]}'
  [ "${lines[0]}" = "custom1" ]
  [ "${lines[1]}" = "custom2" ]
  [ "${lines[2]}" = "(?d).DS_Store" ]
  [ "${lines[3]}" = "(?d)._*" ]
}

@test "_stignore_patterns omits defaults when add_default_ignores is false" {
  run syncthing::_stignore_patterns '{"ignore_patterns":["custom1"],"add_default_ignores":false}'
  [ "$output" = "custom1" ]
}

@test "_stignore_patterns de-duplicates, keeping the user's occurrence" {
  run syncthing::_stignore_patterns '{"ignore_patterns":["(?d).DS_Store"]}'
  [ "${lines[0]}" = "(?d).DS_Store" ]
  [ "${lines[1]}" = "(?d)._*" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "_stignore_patterns emits only defaults when the folder has no patterns" {
  run syncthing::_stignore_patterns '{}'
  [ "${lines[0]}" = "(?d).DS_Store" ]
  [ "${lines[1]}" = "(?d)._*" ]
}

@test "_default_ignores lists the deletable junk patterns" {
  run syncthing::_default_ignores
  [[ "$output" == *"(?d).DS_Store"* ]]
  [[ "$output" == *"(?d)._*"* ]]
}

# --- _join / _accept_pending / _ensure_peers ---

@test "_join adds declared peers and skips pending for a client" {
  STUB_OUTPUT="HUB" mktest::stub_function syncthing::_ensure_peers
  STUB_RETURN=1 mktest::stub_function syncthing::_is_hub
  mktest::stub_function syncthing::_accept_pending
  run syncthing::_join
  [ "$status" -eq 0 ]
  [ "$output" = "HUB" ]
  mktest::assert_stub_not_called syncthing::_accept_pending
}

@test "_join also accepts pending devices for a hub" {
  mktest::stub_function syncthing::_ensure_peers
  mktest::stub_function syncthing::_is_hub
  STUB_OUTPUT=$'DEV1\nDEV2' mktest::stub_function syncthing::_accept_pending
  run syncthing::_join
  [ "$status" -eq 0 ]
  mktest::assert_stub_called syncthing::_accept_pending
  [ "${lines[0]}" = "DEV1" ]
  [ "${lines[1]}" = "DEV2" ]
}

@test "_accept_pending accepts each pending device and outputs its id" {
  STUB_OUTPUT=$'DEV1\nDEV2' mktest::stub_function syncthing::_cli_pending_devices
  mktest::stub_function syncthing::_cli_add_device
  run syncthing::_accept_pending
  [ "${lines[0]}" = "DEV1" ]
  [ "${lines[1]}" = "DEV2" ]
  mktest::assert_stub_called syncthing::_cli_add_device "DEV1" "dynamic" "DEV1" "false"
  mktest::assert_stub_called syncthing::_cli_add_device "DEV2" "dynamic" "DEV2" "false"
}

@test "_accept_pending is a no-op when nothing is pending" {
  mktest::stub_function syncthing::_cli_pending_devices
  mktest::stub_function syncthing::_cli_add_device
  syncthing::_accept_pending
  mktest::assert_stub_not_called syncthing::_cli_add_device
}

# --- _ensure_peers (orchestrator: iterates, delegates per peer) ---

@test "_ensure_peers runs each configured peer through _ensure_peer and passes their ids through" {
  STUB_OUTPUT='[{"device_id":"DEV1"},{"device_id":"DEV2"}]' mktest::stub_function syncthing::_peers
  STUB_OUTPUT="ECHOED" mktest::stub_function syncthing::_ensure_peer
  run syncthing::_ensure_peers
  mktest::assert_stub_called syncthing::_ensure_peer '{"device_id":"DEV1"}'
  mktest::assert_stub_called syncthing::_ensure_peer '{"device_id":"DEV2"}'
  [ "${lines[0]}" = "ECHOED" ]
  [ "${lines[1]}" = "ECHOED" ]
}

@test "_ensure_peers is a no-op when no peers are configured" {
  mktest::stub_function syncthing::_peers
  mktest::stub_function syncthing::_ensure_peer
  syncthing::_ensure_peers
  mktest::assert_stub_not_called syncthing::_ensure_peer
}

# --- _ensure_peer (member: per-peer logic; stubbed CLI) ---

@test "_ensure_peer adds the peer and echoes its device id" {
  mktest::stub_function syncthing::_cli_add_device "DEV1" "tcp://a:22000" "a" "true"
  run syncthing::_ensure_peer '{"device_id":"DEV1","address":"tcp://a:22000","name":"a","introducer":true}'
  [ "$output" = "DEV1" ]
  mktest::assert_stub_called syncthing::_cli_add_device "DEV1" "tcp://a:22000" "a" "true"
}

@test "_ensure_peer defaults address, name, and introducer for a sparse entry" {
  mktest::stub_function syncthing::_cli_add_device "DEV2" "dynamic" "DEV2" "false"
  run syncthing::_ensure_peer '{"device_id":"DEV2"}'
  [ "$output" = "DEV2" ]
  mktest::assert_stub_called syncthing::_cli_add_device "DEV2" "dynamic" "DEV2" "false"
}

# --- _apply_discovery ---

@test "_apply_discovery applies each option from the discovery posture" {
  STUB_OUTPUT=$'global-ann-enabled false\nrelays-enabled false' \
    mktest::stub_function syncthing::_discovery_options
  mktest::stub_function syncthing::_cli_set_option
  syncthing::_apply_discovery
  mktest::assert_stub_called syncthing::_cli_set_option global-ann-enabled false
  mktest::assert_stub_called syncthing::_cli_set_option relays-enabled false
}

@test "_apply_discovery sets nothing when the posture is empty (default)" {
  mktest::stub_function syncthing::_discovery_options
  mktest::stub_function syncthing::_cli_set_option
  syncthing::_apply_discovery
  mktest::assert_stub_not_called syncthing::_cli_set_option
}

# --- _join_consented ---

@test "_join_consented is true when consent is given" {
  STUB_OUTPUT="true" mktest::stub_function context::get "syncthing.join" "--default" "false" "--coerce" "boolean" "--prompt" "Join the Syncthing mesh now (add peers and share folders)? (y/n)"
  syncthing::_join_consented
}

@test "_join_consented is false when consent is withheld" {
  STUB_OUTPUT="false" mktest::stub_function context::get "syncthing.join" "--default" "false" "--coerce" "boolean" "--prompt" "Join the Syncthing mesh now (add peers and share folders)? (y/n)"
  run ! syncthing::_join_consented
}

# --- config accessors ---

@test "_folders returns the configured folders" {
  STUB_OUTPUT='[{"id":"agents","path":"/p"}]' mktest::stub_function config::get "module.syncthing.folders"
  run syncthing::_folders
  [ "$output" = '[{"id":"agents","path":"/p"}]' ]
}

@test "_folders is empty (success) when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get "module.syncthing.folders"
  run syncthing::_folders
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_peers returns the configured peers" {
  STUB_OUTPUT='[{"device_id":"DEV"}]' mktest::stub_function config::get "module.syncthing.peers"
  run syncthing::_peers
  [ "$output" = '[{"device_id":"DEV"}]' ]
}

@test "_peers is empty (success) when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get "module.syncthing.peers"
  run syncthing::_peers
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_is_hub is true when the hub flag is set" {
  STUB_OUTPUT="true" mktest::stub_function config::get "module.syncthing.hub" "--default" "false" "--coerce" "boolean"
  syncthing::_is_hub
}

@test "_is_hub is false by default" {
  STUB_OUTPUT="false" mktest::stub_function config::get "module.syncthing.hub" "--default" "false" "--coerce" "boolean"
  run ! syncthing::_is_hub
}

@test "_discovery_preset returns configured value, defaulting to tailnet" {
  STUB_OUTPUT="the-result" mktest::stub_function config::get "module.syncthing.discovery" "--default" "tailnet"
  run syncthing::_discovery_preset
  [ "$output" = "the-result" ]
}

@test "_discovery_options hardens every path for the tailnet posture" {
  STUB_OUTPUT="tailnet" mktest::stub_function syncthing::_discovery_preset
  run syncthing::_discovery_options
  [[ "$output" == *"global-ann-enabled false"* ]]
  [[ "$output" == *"local-ann-enabled false"* ]]
  [[ "$output" == *"relays-enabled false"* ]]
  [[ "$output" == *"natenabled false"* ]]
}

@test "_discovery_options emits nothing for the default posture" {
  STUB_OUTPUT="default" mktest::stub_function syncthing::_discovery_preset
  run syncthing::_discovery_options
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_discovery_options fails for an unknown posture" {
  STUB_OUTPUT="bogus" mktest::stub_function syncthing::_discovery_preset
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_discovery_options
  MATCH="unknown discovery" mktest::assert_stub_called lifecycle::fail
}

# --- external command seam (real `syncthing`/`brew` stubbed; asserts our
# invocations — distinct from VM QA that the real CLI accepts these commands) ---

@test "_identity_exists is true when syncthing reports a device id" {
  mktest::stub_function syncthing "device-id"
  syncthing::_identity_exists
}

@test "_identity_exists is false when syncthing has no identity yet" {
  STUB_RETURN=1 mktest::stub_function syncthing "device-id"
  run ! syncthing::_identity_exists
}

@test "_generate runs syncthing generate" {
  mktest::stub_function syncthing "generate"
  syncthing::_generate
  mktest::assert_stub_called syncthing "generate"
}

@test "_own_device_id returns the id syncthing prints" {
  STUB_OUTPUT="DEVICE-ABC" mktest::stub_function syncthing "device-id"
  run syncthing::_own_device_id
  [ "$output" = "DEVICE-ABC" ]
}

@test "_cli_pending_devices lists the device ids awaiting approval" {
  STUB_OUTPUT='{"DEV1":{},"DEV2":{}}' mktest::stub_function syncthing "cli" "show" "pending" "devices"
  run syncthing::_cli_pending_devices
  [ "${lines[0]}" = "DEV1" ]
  [ "${lines[1]}" = "DEV2" ]
}

@test "_start starts syncthing as a user-level brew service" {
  mktest::stub_function brew::start_service "syncthing" "user"
  syncthing::_start
  mktest::assert_stub_called brew::start_service "syncthing" "user"
}

@test "_wait_ready returns as soon as the daemon answers the cli" {
  mktest::stub_function syncthing "cli" "show" "system"
  mktest::stub_function sleep
  syncthing::_wait_ready
  mktest::assert_stub_not_called sleep
}

@test "_wait_ready fails when the daemon never becomes ready" {
  STUB_RETURN=1 mktest::stub_function syncthing "cli" "show" "system"
  mktest::stub_function sleep
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! syncthing::_wait_ready
  MATCH="did not become ready" mktest::assert_stub_called lifecycle::fail
}

@test "_cli_set_option sets the named option to the given value" {
  mktest::stub_function syncthing "cli" "config" "options" "someSyncthingOption" "set" "someValue"
  syncthing::_cli_set_option "someSyncthingOption" "someValue"
  mktest::assert_stub_called syncthing "cli" "config" "options" "someSyncthingOption" "set" "someValue"
}

@test "_cli_ensure_folder upserts the folder and shares it with each device" {
  mktest::stub_function syncthing
  syncthing::_cli_ensure_folder "agents" "/p" "DEV1 DEV2"
  mktest::assert_stub_called syncthing "cli" "config" "folders" "add" "--id" "agents" "--path" "/p"
  mktest::assert_stub_called syncthing "cli" "config" "folders" "agents" "devices" "add" "--device-id" "DEV1"
  mktest::assert_stub_called syncthing "cli" "config" "folders" "agents" "devices" "add" "--device-id" "DEV2"
  mktest::assert_stub_not_called syncthing "cli" "config" "folders" "agents" "path" "set" "/p"
}

@test "_cli_ensure_folder falls back to setting the path when the folder already exists" {
  STUB_RETURN=1 mktest::stub_function syncthing "cli" "config" "folders" "add" "--id" "agents" "--path" "/p"
  mktest::stub_function syncthing
  syncthing::_cli_ensure_folder "agents" "/p" ""
  mktest::assert_stub_called syncthing "cli" "config" "folders" "agents" "path" "set" "/p"
}

@test "_cli_add_device adds the device, delegates its address, and sets introducer" {
  mktest::stub_function syncthing
  mktest::stub_function syncthing::_cli_set_address
  syncthing::_cli_add_device "DEV" "tcp://h:22000" "name" "true"
  mktest::assert_stub_called syncthing "cli" "config" "devices" "add" "--device-id" "DEV" "--name" "name"
  mktest::assert_stub_called syncthing::_cli_set_address "DEV" "tcp://h:22000"
  mktest::assert_stub_called syncthing "cli" "config" "devices" "DEV" "introducer" "set" "true"
}

@test "_cli_set_address adds a static address not already configured" {
  STUB_OUTPUT='{"addresses":["dynamic"]}' mktest::stub_function syncthing "cli" "config" "devices" "DEV" "dump-json"
  mktest::stub_function syncthing "cli" "config" "devices" "DEV" "addresses" "add" "tcp://h:22000"
  syncthing::_cli_set_address "DEV" "tcp://h:22000"
  mktest::assert_stub_called syncthing "cli" "config" "devices" "DEV" "addresses" "add" "tcp://h:22000"
}

@test "_cli_set_address does not re-add an address that is already configured" {
  STUB_OUTPUT='{"addresses":["dynamic","tcp://h:22000"]}' mktest::stub_function syncthing "cli" "config" "devices" "DEV" "dump-json"
  mktest::stub_function syncthing "cli" "config" "devices" "DEV" "addresses" "add" "tcp://h:22000"
  syncthing::_cli_set_address "DEV" "tcp://h:22000"
  mktest::assert_stub_not_called syncthing "cli" "config" "devices" "DEV" "addresses" "add" "tcp://h:22000"
}

@test "_cli_set_address leaves the default 'dynamic' address alone" {
  mktest::stub_function syncthing
  syncthing::_cli_set_address "DEV" "dynamic"
  mktest::assert_stub_not_called syncthing
}

@test "_cli_set_address is a no-op for an empty address" {
  mktest::stub_function syncthing
  syncthing::_cli_set_address "DEV" ""
  mktest::assert_stub_not_called syncthing
}
