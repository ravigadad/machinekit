#!/usr/bin/env bash
# Source-agnostic fetch core: given a source address (URL or local path) and a
# destination directory, lay the source down at the destination.
#
# Protocol is auto-sniffed from the source, overridable by the caller:
#   URL                → git clone
#   path with .git/    → git clone (override to "cp" to copy instead)
#   path without .git/ → cp
#
# This is the shared machinery behind blueprints::fetch and agents_config_setup;
# each owns its own destination lifecycle (where dest comes from, when to run,
# dry-run handling) and calls fetch::resolve_protocol + fetch::into. The git path
# carries SSH-key fallback and auth/network/not-found error classification.
[ -n "${_MK_FETCH_LOADED:-}" ] && return 0
_MK_FETCH_LOADED=1

# fetch::resolve_protocol SOURCE [OVERRIDE]
# Prints "git" or "cp". With no override, sniffs from the source; an override is
# honored verbatim. Either way the result is validated (cp is incompatible with a
# URL; anything other than git/cp is rejected).
fetch::resolve_protocol() {
  local source="$1" protocol="${2:-}"

  if [ -z "$protocol" ]; then
    if fetch::_is_url "$source" || [ -d "${source}/.git" ]; then
      protocol="git"
    else
      protocol="cp"
    fi
  fi

  case "$protocol" in
    git) ;;
    cp)
      fetch::_is_url "$source" && \
        lifecycle::fail "Protocol 'cp' is not compatible with a URL source: $source"
      ;;
    *)
      lifecycle::fail "Unknown fetch protocol: $protocol (valid: git, cp)"
      ;;
  esac

  printf '%s\n' "$protocol"
}

# fetch::into SOURCE DEST PROTOCOL [SHALLOW]
# Lays SOURCE down at DEST using an already-resolved PROTOCOL. DEST must not be a
# non-empty directory (git clone refuses one); cp creates it. A non-empty SHALLOW
# requests a history-less git clone (--depth 1) — for consumers that read only the
# current tree and never its history; ignored on the cp path, which carries no
# history to shorten.
fetch::into() {
  local source="$1" dest="$2" protocol="$3" shallow="${4:-}"
  case "$protocol" in
    git) fetch::_git "$source" "$dest" "$shallow" ;;
    cp)  fetch::_cp  "$source" "$dest" ;;
    *)   lifecycle::fail "Unknown fetch protocol: $protocol (valid: git, cp)" ;;
  esac
}

fetch::_git() {
  local source="$1" dest="$2" shallow="${3:-}" abs_source="$1"
  fetch::_is_url "$source" || abs_source=$(fetch::_resolve_source_path "$source")

  local ssh_was_setup=0
  fetch::_provision_ssh_for_clone && ssh_was_setup=1

  logging::info "Cloning $abs_source → $dest"
  fetch::_clone_with_recovery "$abs_source" "$dest" "$ssh_was_setup" "$shallow"
}

# Provision an SSH key up front when the user passed key flags, so SSH URLs work
# on the first clone attempt. Returns 0 (and sets the key up) when it did, 1 when
# there was nothing to provision — the caller records that to know whether a later
# auth failure is recoverable or terminal.
fetch::_provision_ssh_for_clone() {
  local existing_key generate
  existing_key=$(context::get "existing_ssh_key_file" || true)
  if [ -n "$existing_key" ]; then
    ssh::setup_key
    return 0
  fi
  generate=$(context::get "ssh.key_generate" --coerce boolean --default false)
  if [ "$generate" = "true" ]; then
    ssh::setup_key
    return 0
  fi
  return 1
}

# Clone abs_source into dest; on failure, classify the error and either recover
# (set up SSH and retry once) or fail. ssh_was_setup says whether a key was
# already provisioned, so a repeat auth failure is terminal rather than retried.
fetch::_clone_with_recovery() {
  local abs_source="$1" dest="$2" ssh_was_setup="$3" shallow="${4:-}"

  # --depth 1 when the caller wants only the current tree, not history. Empty array
  # expands to nothing on a full clone, so the git line stays the same either way.
  local depth_args=()
  if [ -n "$shallow" ]; then
    depth_args=(--depth 1)
  fi

  # Capture stderr so we can classify auth vs network vs not-found on failure.
  # Progress output is sacrificed; on success the output is discarded silently.
  local stderr_file clone_rc=0
  stderr_file=$(mktemp)
  git clone "${depth_args[@]}" -- "$abs_source" "$dest" 2>"$stderr_file" || clone_rc=$?
  if [ "$clone_rc" -eq 0 ]; then
    rm -f "$stderr_file"
    return 0
  fi

  local stderr_out
  stderr_out=$(cat "$stderr_file")
  rm -f "$stderr_file"
  printf '%s\n' "$stderr_out" >&2
  fetch::_handle_clone_failure "$stderr_out" "$abs_source" "$ssh_was_setup"
  logging::step "Retrying clone after SSH key setup..."
  git clone "${depth_args[@]}" -- "$abs_source" "$dest"
}

# fetch::_classify_clone_error STDERR_OUT
# Inspects captured git stderr and prints one of: auth, network, not_found, unknown.
fetch::_classify_clone_error() {
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

# fetch::_handle_clone_failure STDERR_OUT SOURCE SSH_WAS_SETUP
# Called when git clone fails. Either sets up SSH and returns 0 (caller retries),
# or exits via lifecycle::fail. Never returns non-zero.
fetch::_handle_clone_failure() {
  local stderr_out="$1" source="$2" ssh_was_setup="${3:-0}"
  local error_type is_ssh_url=0
  error_type=$(fetch::_classify_clone_error "$stderr_out")

  case "$source" in
    git@*|ssh://*) is_ssh_url=1 ;;
  esac

  case "$error_type" in
    auth)
      fetch::_handle_clone_auth_failure "$source" "$is_ssh_url" "$ssh_was_setup"
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

# fetch::_handle_clone_auth_failure SOURCE IS_SSH_URL SSH_WAS_SETUP
# Recovery (set up SSH, return 0 to retry) is limited to the one case it can help:
# an SSH URL, interactive, no key tried yet. Every other path is terminal —
# retrying wouldn't change the outcome.
fetch::_handle_clone_auth_failure() {
  local source="$1" is_ssh_url="$2" ssh_was_setup="$3"
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
}

fetch::_cp() {
  local source="$1" dest="$2" abs_source
  abs_source=$(fetch::_resolve_source_path "$source")
  logging::info "Copying $abs_source → $dest"
  mkdir -p "$dest"
  cp -R -- "$abs_source/." "$dest/"
}

# Looks-like-a-URL check for sources git clone accepts as remotes.
fetch::_is_url() {
  case "$1" in
    http://*|https://*|ssh://*|git@*|file://*) return 0 ;;
    *) return 1 ;;
  esac
}

fetch::_resolve_source_path() {
  local in="$1" abs
  [ -e "$in" ] || lifecycle::fail "Source path does not exist: $in"
  [ -d "$in" ] || lifecycle::fail "Source path is not a directory: $in"
  abs=$(cd "$in" && pwd) || lifecycle::fail "Could not resolve source path: $in"
  [ -n "$(ls -A "$abs")" ] || lifecycle::fail "Source path is empty: $in"
  printf '%s\n' "$abs"
}
