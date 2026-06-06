#!/usr/bin/env bash
# Blueprint source resolution and fetch helpers.
#
# blueprints::fetch resolves the source address, sniffs the protocol, sets up
# the destination directory, and delegates to the appropriate fetch helper.
# Once fetch has run, blueprints::dir returns the destination directory.
#
# Source address: any URL or local path (context key: blueprints.source).
# Protocol: auto-sniffed from the source, overridable via blueprints.source_protocol.
#   URL                → git clone
#   path with .git/    → git clone (override to "cp" to copy instead)
#   path without .git/ → cp
[ -n "${_MK_BLUEPRINTS_LOADED:-}" ] && return 0
_MK_BLUEPRINTS_LOADED=1

# Permanent destination — exported so hooks can reference it.
export MACHINEKIT_BLUEPRINTS_DIR="$HOME/.local/share/machinekit/blueprints"

# Holds the active destination path during a fetch session (temp until finalized).
_MK_BLUEPRINTS_DIR=""

blueprints::fetch() {
  local source protocol
  source=$(context::get "blueprints.source" --required)
  protocol=$(blueprints::_resolve_protocol "$source")

  blueprints::_prepare_dest
  logging::step "Fetching blueprints ($protocol): $source"

  case "$protocol" in
    git) blueprints::_fetch_git "$source" ;;
    cp)  blueprints::_fetch_cp  "$source" ;;
  esac

  if ! input::is_dry_run; then
    mkdir -p "$(dirname "$MACHINEKIT_BLUEPRINTS_DIR")"
    rm -rf -- "$MACHINEKIT_BLUEPRINTS_DIR"
    mv "$_MK_BLUEPRINTS_DIR" "$MACHINEKIT_BLUEPRINTS_DIR"
    _MK_BLUEPRINTS_DIR="$MACHINEKIT_BLUEPRINTS_DIR"
  fi
}

blueprints::dir() {
  [ -n "$_MK_BLUEPRINTS_DIR" ] || lifecycle::fail "blueprints::dir called before blueprints::fetch"
  printf '%s\n' "$_MK_BLUEPRINTS_DIR"
}

blueprints::_resolve_protocol() {
  local source="$1"
  local protocol
  protocol=$(context::get "blueprints.source_protocol") || true

  if [ -z "$protocol" ]; then
    if blueprints::_is_url "$source" || [ -d "${source}/.git" ]; then
      protocol="git"
    else
      protocol="cp"
    fi
    context::set "blueprints.source_protocol" "$protocol"
  fi

  case "$protocol" in
    git) ;;
    cp)
      blueprints::_is_url "$source" && \
        lifecycle::fail "Protocol 'cp' is not compatible with a URL source: $source"
      ;;
    *)
      lifecycle::fail "Unknown blueprints protocol: $protocol (valid: git, cp)"
      ;;
  esac

  printf '%s\n' "$protocol"
}

blueprints::_prepare_dest() {
  _MK_BLUEPRINTS_DIR=$(mktemp -d)
  # git clone refuses a non-empty dir; drop the mktemp dir so clone/copy
  # creates it fresh.
  rmdir "$_MK_BLUEPRINTS_DIR"
  lifecycle::register_cleanup blueprints::cleanup_dest
}

blueprints::_fetch_git() {
  local source="$1" abs_source="$1"
  blueprints::_is_url "$source" || abs_source=$(blueprints::_resolve_source_path "$source")

  # Proactive SSH setup when the user explicitly passed key flags — installs or
  # generates the key before the first clone attempt so SSH URLs work first try.
  local ssh_was_setup=0
  local existing_key
  existing_key=$(context::get "existing_ssh_key_file" || true)
  if [ -n "$existing_key" ]; then
    ssh::setup_key
    ssh_was_setup=1
  else
    local generate
    generate=$(context::get "ssh.key_generate" --coerce boolean --default false)
    if [ "$generate" = "true" ]; then
      ssh::setup_key
      ssh_was_setup=1
    fi
  fi

  logging::info "Cloning $abs_source → $_MK_BLUEPRINTS_DIR"

  # Capture stderr so we can classify auth vs network vs not-found on failure.
  # Progress output is sacrificed; on success the output is discarded silently.
  local stderr_file clone_rc=0
  stderr_file=$(mktemp)
  git clone -- "$abs_source" "$_MK_BLUEPRINTS_DIR" 2>"$stderr_file" || clone_rc=$?

  if [ "$clone_rc" -ne 0 ]; then
    local stderr_out
    stderr_out=$(cat "$stderr_file")
    rm -f "$stderr_file"
    printf '%s\n' "$stderr_out" >&2
    blueprints::_handle_clone_failure "$stderr_out" "$abs_source" "$ssh_was_setup"
    logging::step "Retrying clone after SSH key setup..."
    git clone -- "$abs_source" "$_MK_BLUEPRINTS_DIR"
    return
  fi

  rm -f "$stderr_file"
}

# blueprints::_classify_clone_error STDERR_OUT
# Inspects captured git stderr and prints one of: auth, network, not_found, unknown.
blueprints::_classify_clone_error() {
  local stderr_out="$1"
  case "$stderr_out" in
    *"Permission denied"*|*"terminal prompts disabled"*|*"could not read Username"*)
      printf 'auth\n' ;;
    *"Could not resolve host"*|*"Network is unreachable"*|*"Connection refused"*|*"connect to host"*)
      printf 'network\n' ;;
    *"Repository not found"*)
      printf 'not_found\n' ;;
    *)
      printf 'unknown\n' ;;
  esac
}

# blueprints::_handle_clone_failure STDERR_OUT SOURCE SSH_WAS_SETUP
# Called when git clone fails. Either sets up SSH and returns 0 (caller retries),
# or exits via lifecycle::fail. Never returns non-zero.
blueprints::_handle_clone_failure() {
  local stderr_out="$1" source="$2" ssh_was_setup="${3:-0}"
  local error_type is_ssh_url=0
  error_type=$(blueprints::_classify_clone_error "$stderr_out")

  case "$source" in
    git@*|ssh://*) is_ssh_url=1 ;;
  esac

  case "$error_type" in
    auth)
      if [ "$is_ssh_url" = 1 ] && [ "$ssh_was_setup" = 1 ]; then
        lifecycle::fail "Clone failed: SSH key installed but authentication still failed. Verify the key is authorized for $source."
      elif [ "$is_ssh_url" = 1 ] && input::is_interactive >/dev/null; then
        logging::warn "SSH authentication failed — setting up SSH key and retrying."
        ssh::setup_key
      elif [ "$is_ssh_url" = 1 ]; then
        lifecycle::fail "SSH authentication failed. Rerun with --existing-ssh-key-file or --generate-ssh-key."
      else
        lifecycle::fail "Clone failed (authentication). Configure git credentials or switch to an SSH URL with --existing-ssh-key-file or --generate-ssh-key."
      fi
      ;;
    network)
      lifecycle::fail "Clone failed: check your network connection and try again."
      ;;
    not_found)
      if [ "$is_ssh_url" = 1 ]; then
        lifecycle::fail "Repository not found: $source"
      else
        lifecycle::fail "Repository not found, or this may be a private repo — HTTPS cannot distinguish. Switch to an SSH URL with --existing-ssh-key-file or --generate-ssh-key."
      fi
      ;;
    *)
      lifecycle::fail "Clone failed. Git output: $stderr_out"
      ;;
  esac
}

blueprints::_fetch_cp() {
  local abs_source
  abs_source=$(blueprints::_resolve_source_path "$1")
  logging::info "Copying $abs_source → $_MK_BLUEPRINTS_DIR"
  mkdir -p "$_MK_BLUEPRINTS_DIR"
  cp -R -- "$abs_source/." "$_MK_BLUEPRINTS_DIR/"
}

# Looks-like-a-URL check for sources git clone accepts as remotes.
blueprints::_is_url() {
  case "$1" in
    http://*|https://*|ssh://*|git@*|file://*) return 0 ;;
    *) return 1 ;;
  esac
}

blueprints::_resolve_source_path() {
  local in="$1" abs
  [ -e "$in" ] || lifecycle::fail "Blueprint source path does not exist: $in"
  [ -d "$in" ] || lifecycle::fail "Blueprint source path is not a directory: $in"
  abs=$(cd "$in" && pwd) || lifecycle::fail "Could not resolve blueprint source path: $in"
  [ -n "$(ls -A "$abs")" ] || lifecycle::fail "Blueprint source path is empty: $in"
  printf '%s\n' "$abs"
}

blueprints::cleanup_dest() {
  [ -n "$_MK_BLUEPRINTS_DIR" ] || return 0
  rm -rf -- "$_MK_BLUEPRINTS_DIR"
  _MK_BLUEPRINTS_DIR=""
}
