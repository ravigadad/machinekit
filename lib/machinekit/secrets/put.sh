#!/usr/bin/env bash
# secrets put — file a secret as an .age in a blueprint working tree. Resolve the
# target (or pick one) and settle any overwrite, then either encrypt a plaintext
# value or, when the source is already age-encrypted, verify and copy it as-is.
# Never touches git — the caller commits.
[ -n "${_MK_SECRETS_PUT_LOADED:-}" ] && return 0
_MK_SECRETS_PUT_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../secrets.sh"

# secrets::put TARGET FROM_FILE — the put use-case. TARGET is the positional path
# (empty → pick interactively); FROM_FILE is --from-file (empty → stdin/prompt).
# A FROM_FILE that is already age-encrypted is verified and copied as-is; anything
# else is treated as plaintext and encrypted. Modules must already be sourced.
secrets::put() {
  local target_arg="$1" from_file="$2" target dest
  target="$(secrets::put::_target "$target_arg")"
  if [ -z "$target" ]; then
    input::is_interactive \
      || lifecycle::fail "secrets: no target — give a <path> argument or set MACHINEKIT_SECRETS_PATH."
    # resolve_inputs fetches the blueprint and arms an EXIT cleanup trap, so it
    # MUST run in this shell — never inside the $() that captures the pick, where
    # the subshell's exit would fire the whole cleanup chain (context store, the
    # fetched blueprint) and tear down state the rest of put needs.
    preflight::resolve_inputs
    target="$(secrets::put::_pick)"
  fi
  dest="$(secrets::dest_path "$target")"
  secrets::put::_confirm_overwrite "$dest"
  if [ -n "$from_file" ] && age::is_encrypted_file "$from_file"; then
    secrets::put::_from_encrypted "$from_file" "$dest"
  else
    secrets::put::_from_plaintext "$from_file" "$dest"
  fi
  logging::success "secrets: wrote $dest"
  logging::info "Commit and push it from your blueprint to propagate to the fleet."
}

# Encrypt a plaintext secret to the recipient and place it. FROM_FILE empty means
# the value comes from piped stdin or an interactive prompt.
secrets::put::_from_plaintext() {
  local from_file="$1" dest="$2" recipient value
  recipient="$(secrets::put::_recipient)"
  # Materialize the value before placing: a failed read must abort here, never
  # mid-pipe where place would already be encrypting empty stdin onto the dest.
  # The printf-x guard preserves exact trailing bytes (e.g. a key's final newline)
  # that $() would otherwise strip.
  value="$(secrets::put::_read_value "$from_file"; printf x)" || exit 1
  value="${value%x}"
  # Never write an empty secret — almost always a mistake, and it would clobber a
  # real one. Guards every empty source (empty stdin, empty file, a missed value).
  [ -n "$value" ] || lifecycle::fail "secrets: refusing to write an empty secret value."
  printf '%s' "$value" | secrets::place "$recipient" "$dest"
}

# File an already-encrypted secret as-is: verify this machine's key can decrypt it
# (age files don't reveal their recipients, so a trial decryption is the only
# check), then copy the ciphertext verbatim — never re-encrypt. A --recipient
# override can't apply to a copy, so it is rejected rather than silently ignored.
secrets::put::_from_encrypted() {
  local from_file="$1" dest="$2" override
  override="$(context::get "secrets.recipient" || true)"
  [ -z "$override" ] \
    || lifecycle::fail "secrets: --recipient can't retarget an already-encrypted file; it is copied as-is. Remove --recipient, or pass the plaintext to re-encrypt."
  age::can_decrypt "$from_file" \
    || lifecycle::fail "secrets: $from_file is age-encrypted, but your local key can't decrypt it — it isn't a recipient. The file may be perfectly valid, just not for this key. If you can't decrypt it and only mean to file it into the pool, copy it in manually."
  secrets::place_file "$from_file" "$dest"
}

# The age recipient to encrypt to: the explicit override, else the public key
# derived from the installed identity.
secrets::put::_recipient() {
  local override
  override="$(context::get "secrets.recipient" || true)"
  [ -n "$override" ] && { printf '%s\n' "$override"; return 0; }
  age::recipient
}

# The target path from the positional argument or MACHINEKIT_SECRETS_PATH, or empty
# when neither is given (the caller then drives the interactive picker). Picking is
# NOT done here — it must not be wrapped in the $() that captures this output.
secrets::put::_target() {
  [ -n "$1" ] && { printf '%s\n' "$1"; return 0; }
  context::get "secrets.path" || true
}

# Interactive picker: present the inventory as a numbered menu on stderr and read a
# choice from the tty; the chosen pool path is the only thing on stdout. Read only
# — the caller resolves inputs first (in the main shell), so this is safe in $().
secrets::put::_pick() {
  local rows; rows="$(secrets::inventory)"
  [ -n "$rows" ] || lifecycle::fail "secrets: no declared secrets to choose from — give a <path> argument."
  local -a paths=()
  local count=0 path state
  while IFS=$'\t' read -r path _ _ state; do
    [ -n "$path" ] || continue
    count=$((count + 1)); paths+=("$path")
    printf '%3d) %s  [%s]\n' "$count" "$path" "$state" >&2
  done <<< "$rows"
  local choice
  printf 'Select a secret to provide [1-%d]: ' "$count" >&2
  read -r choice < "${MACHINEKIT_TTY:-/dev/tty}"
  { [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; } 2>/dev/null \
    || lifecycle::fail "secrets: invalid selection: $choice"
  printf '%s\n' "${paths[$((choice - 1))]}"
}

# Require confirmation before replacing an existing secret. The confirm flows
# through the normal chain — --overwrite / MACHINEKIT_SECRETS_OVERWRITE / prompt —
# so both modes gate it. A non-existent target needs no confirmation.
secrets::put::_confirm_overwrite() {
  local dest="$1" ok
  [ -e "$dest" ] || return 0
  ok="$(context::get "secrets.overwrite" --coerce boolean --default false \
    --prompt "Overwrite the existing secret at $dest? (y/n)")"
  [ "$ok" = true ] || lifecycle::fail "secrets: $dest already exists; not overwritten (pass --overwrite to allow)."
}

# Emit the plaintext value on stdout for piping into place: an explicit FROM_FILE
# wins, then piped stdin, then an interactive hidden prompt. FROM_FILE is checked
# first because stdin is non-tty for any redirect (a script, /dev/null), which
# would otherwise shadow the file with an empty stream. Non-interactive with none
# is a hard failure (never an argument, to keep the value out of shell history).
secrets::put::_read_value() {
  local from_file="$1"
  if [ -n "$from_file" ]; then
    [ -f "$from_file" ] || lifecycle::fail "secrets: --from-file not found: $from_file"
    cat "$from_file"
  elif ! input::stdin_is_tty; then
    cat
  elif input::is_interactive; then
    secrets::put::_prompt_value
  else
    lifecycle::fail "secrets: no value — pipe it on stdin or pass --from-file."
  fi
}

# Read a secret value from the tty without echoing it, never through context (so it
# can't be set via env and never lands in the store). Value to stdout.
secrets::put::_prompt_value() {
  local value
  printf 'Secret value (input hidden): ' >&2
  read -rs value < "${MACHINEKIT_TTY:-/dev/tty}"
  printf '\n' >&2
  printf '%s' "$value"
}
