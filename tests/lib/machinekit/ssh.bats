#!/usr/bin/env bats
# Tests for lib/machinekit/ssh.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/ssh.sh
  source "$MACHINEKIT_DIR/lib/machinekit/ssh.sh"
  SSH_KEY_PATH="$BATS_TEST_TMPDIR/ssh/id_ed25519"
  unset MACHINEKIT_EXISTING_SSH_KEY_FILE
}

# --- ssh::setup_key ---

@test "setup_key is a no-op when no flags are given" {
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  run ssh::setup_key
  [ "$status" -eq 0 ]
}

@test "setup_key with existing key file copies and logs the plan" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key"
  printf 'fake key\n' > "$keyfile"
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_ssh_key_file"
  mktest::stub_function ssh::_install_copy
  ssh::setup_key
  mktest::assert_stub_called ssh::_install_copy "$keyfile" "$SSH_KEY_PATH"
}

@test "setup_key calls _confirm_overwrite when existing key file conflicts with destination" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key"
  printf 'fake key\n' > "$keyfile"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  printf 'existing\n' > "$SSH_KEY_PATH"
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_ssh_key_file"
  mktest::stub_function ssh::_confirm_overwrite
  mktest::stub_function ssh::_install_copy
  ssh::setup_key
  mktest::assert_stub_called ssh::_confirm_overwrite "$SSH_KEY_PATH"
  mktest::assert_stub_called ssh::_install_copy "$keyfile" "$SSH_KEY_PATH"
}

@test "setup_key fails when the provided key file does not exist" {
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/no-such-key" mktest::stub_function context::get "existing_ssh_key_file"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! ssh::setup_key
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

@test "setup_key with generate=true calls _generate" {
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::_generate
  ssh::setup_key
  mktest::assert_stub_called ssh::_generate "$SSH_KEY_PATH"
}

@test "setup_key with generate=true calls _confirm_overwrite when key already exists" {
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  printf 'existing\n' > "$SSH_KEY_PATH"
  STUB_OUTPUT="$SSH_KEY_PATH" mktest::stub_function context::get "ssh.key_path" "--default" "$SSH_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::_confirm_overwrite
  mktest::stub_function ssh::_generate
  ssh::setup_key
  mktest::assert_stub_called ssh::_confirm_overwrite "$SSH_KEY_PATH"
  mktest::assert_stub_called ssh::_generate "$SSH_KEY_PATH"
}

# --- ssh::_confirm_overwrite ---

@test "_confirm_overwrite succeeds when overwrite is confirmed" {
  local overwrite_prompt
  # shellcheck disable=SC2059
  printf -v overwrite_prompt "$_SSH_OVERWRITE_PROMPT" "$SSH_KEY_PATH"
  STUB_OUTPUT="true" mktest::stub_function context::get "ssh.key_overwrite" "--required" "--coerce" "boolean" "--prompt" "$overwrite_prompt"
  ssh::_confirm_overwrite "$SSH_KEY_PATH"
}

@test "_confirm_overwrite fails when overwrite is declined" {
  local overwrite_prompt
  # shellcheck disable=SC2059
  printf -v overwrite_prompt "$_SSH_OVERWRITE_PROMPT" "$SSH_KEY_PATH"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_overwrite" "--required" "--coerce" "boolean" "--prompt" "$overwrite_prompt"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! ssh::_confirm_overwrite "$SSH_KEY_PATH"
  MATCH="not overwritten" mktest::assert_stub_called lifecycle::fail
}

# --- ssh::_install_copy ---

@test "_install_copy creates the key dir with 700, copies the key with 600, and logs success" {
  local src="$BATS_TEST_TMPDIR/src-key"
  printf 'key content\n' > "$src"
  mktest::stub_function logging::success
  ssh::_install_copy "$src" "$SSH_KEY_PATH"
  [ "$(cat "$SSH_KEY_PATH")" = "key content" ]
  [ "$(mktest::file_mode "$SSH_KEY_PATH")" = "600" ]
  [ "$(mktest::file_mode "$(dirname "$SSH_KEY_PATH")")" = "700" ]
  mktest::assert_stub_called logging::success
}

# --- ssh::_generate ---

@test "_generate invokes ssh-keygen, sets 600 permissions, and calls _show_pubkey_instructions" {
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  printf '' > "$SSH_KEY_PATH"
  mktest::stub_function logging::success
  mktest::stub_function ssh-keygen "-t" "ed25519" "-f" "$SSH_KEY_PATH" "-N" ""
  STUB_OUTPUT="ssh-ed25519 AAAAfake test@test" mktest::stub_function ssh-keygen "-y" "-f" "$SSH_KEY_PATH"
  mktest::stub_function ssh::_show_pubkey_instructions "ssh-ed25519 AAAAfake test@test"
  ssh::_generate "$SSH_KEY_PATH"
  mktest::assert_stub_called ssh-keygen "-t" "ed25519" "-f" "$SSH_KEY_PATH" "-N" ""
  [ "$(mktest::file_mode "$SSH_KEY_PATH")" = "600" ]
  mktest::assert_stub_called ssh::_show_pubkey_instructions "ssh-ed25519 AAAAfake test@test"
}

# --- ssh::_show_pubkey_instructions ---

@test "_show_pubkey_instructions prints the pubkey and provider URLs" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  run --separate-stderr ssh::_show_pubkey_instructions "ssh-ed25519 AAAAfake test@test"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"ssh-ed25519 AAAAfake"* ]]
  [[ "$stderr" == *"github.com"* ]]
}

@test "_show_pubkey_instructions pauses for input in interactive mode" {
  mktest::stub_function input::is_interactive
  printf '\n' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run --separate-stderr ssh::_show_pubkey_instructions "ssh-ed25519 AAAAfake test@test"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Press Enter"* ]]
}
