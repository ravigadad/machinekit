#!/usr/bin/env bash
# SSH key management — installs or generates the user's SSH key before the
# blueprints fetch so SSH-authenticated git clones work on a fresh machine.
[ -n "${_MK_SSH_LOADED:-}" ] && return 0
_MK_SSH_LOADED=1

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

_SSH_OVERWRITE_PROMPT="WARNING: An SSH key already exists at %s. Overwriting may break access to services that depend on it. Only proceed if you want to replace it. Overwrite? (y/n)"

ssh::setup_key() {
  local key_path existing_key_file generate
  key_path=$(context::get "ssh.key_path" --default "$SSH_KEY_PATH" --store-default)
  existing_key_file=$(context::get "existing_ssh_key_file" || true)
  existing_key_file="${existing_key_file/#\~/$HOME}"

  if [ -n "$existing_key_file" ]; then
    [ -f "$existing_key_file" ] || lifecycle::fail "SSH key not found at: $existing_key_file"
    [ -f "$key_path" ] && ssh::_confirm_overwrite "$key_path"
    ssh::_install_copy "$existing_key_file" "$key_path"
  else
    generate=$(context::get "ssh.key_generate" --coerce boolean --default false)
    if [ "$generate" = "true" ]; then
      [ -f "$key_path" ] && ssh::_confirm_overwrite "$key_path"
      ssh::_generate "$key_path"
    elif input::is_interactive >/dev/null; then
      ssh::_interactive_discover "$key_path"
    fi
  fi
}

# ssh::_interactive_discover KEY_PATH
# Prompts for a key path (blank → generate). Called when no explicit SSH flags
# were given but auth failed and the session is interactive.
ssh::_interactive_discover() {
  local key_path="$1" provided_path
  printf 'Path to SSH private key (leave blank to generate a new one): ' >&2
  read -r provided_path < "${MACHINEKIT_TTY:-/dev/tty}"
  provided_path="${provided_path/#\~/$HOME}"
  if [ -n "$provided_path" ]; then
    [ -f "$provided_path" ] || lifecycle::fail "SSH key not found at: $provided_path"
    [ -f "$key_path" ] && ssh::_confirm_overwrite "$key_path"
    ssh::_install_copy "$provided_path" "$key_path"
  else
    [ -f "$key_path" ] && ssh::_confirm_overwrite "$key_path"
    ssh::_generate "$key_path"
  fi
}

ssh::_confirm_overwrite() {
  local key_path="$1" overwrite overwrite_prompt
  # shellcheck disable=SC2059
  printf -v overwrite_prompt "$_SSH_OVERWRITE_PROMPT" "$key_path"
  overwrite=$(context::get "ssh.key_overwrite" --required --coerce boolean --prompt "$overwrite_prompt")
  [ "$overwrite" = "true" ] || lifecycle::fail "SSH key not overwritten. Remove $key_path first, or omit the conflicting flag to use the existing key."
}

ssh::_install_copy() {
  local src="$1" key_path="$2" key_dir
  key_dir="$(dirname "$key_path")"
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  cp "$src" "$key_path"
  chmod 600 "$key_path"
  logging::success "Installed SSH key from $src"
}

ssh::_generate() {
  local key_path="$1" key_dir pubkey
  key_dir="$(dirname "$key_path")"
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  ssh-keygen -t ed25519 -f "$key_path" -N "" >/dev/null 2>&1
  chmod 600 "$key_path"
  pubkey="$(ssh-keygen -y -f "$key_path")"
  logging::success "Generated SSH key at $key_path"
  ssh::_show_pubkey_instructions "$pubkey"
}

ssh::_show_pubkey_instructions() {
  local pubkey="$1"
  printf '\nAdd this public key to your git provider:\n\n    %s\n\n' "$pubkey" >&2
  printf '  GitHub:    https://github.com/settings/ssh/new\n' >&2
  printf '  GitLab:    https://gitlab.com/-/user_settings/ssh_keys\n' >&2
  printf '  Bitbucket: https://bitbucket.org/account/settings/ssh-keys/\n\n' >&2
  if input::is_interactive >/dev/null; then
    printf 'Press Enter when done...' >&2
    read -r _ < "${MACHINEKIT_TTY:-/dev/tty}"
  fi
}
