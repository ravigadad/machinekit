#!/usr/bin/env bash
# age module — handles the user's age private key.
#
# Two-phase:
#   age::preflight  — decide what to do; no side effects. May prompt.
#   age::install    — execute the plan decided in preflight.

# Canonical location for the user's age private key.
AGE_KEY_PATH="$HOME/.config/age/key.txt"

_AGE_OVERWRITE_PROMPT="WARNING: A key already exists at %s. Overwriting will permanently destroy access to any files encrypted with the current key. Only proceed if you have a backup or no encrypted files depend on it. Overwrite? (y/n)"

_AGE_GENERATE_PROMPT="No age key found at %s. Generate a new one? (y/n)"

# Depends on the secrets_manager capability exactly when key_source_type is
# secrets_manager — an intent directive, not a presence check. It must pull the
# manager into the graph even for a convention-backed key, which declares no
# explicit reference and so would surface through neither backend_requirements nor
# a pool file. The plain file paths (generate, hand-placed) need no manager.
# Config loads before the resolver calls requires.
age::requires() {
  age::_manager_sources_key && printf 'secrets_manager\n'
  return 0
}

# The named secret the age key resolves under, for the inventory (machinekit
# secrets list) — a single row, required and not locally generatable (a
# manager-sourced key must match the fleet's; minting a fresh one would diverge).
# Emitted only when key_source_type is secrets_manager: on the file paths the key
# is a local artifact, not a pool/manager secret to track.
age::declared_secrets() {
  age::_manager_sources_key || return 0
  printf '%s\ttrue\tfalse\n' "$_MK_SECRETS_AGE_KEY_NAME"
}

age::preflight() {
  local key_path existing_key_file generate
  key_path=$(config::get "module.age.key_path" --default "$AGE_KEY_PATH" --store-default)
  existing_key_file=$(context::get "existing_age_key_file" || true)

  if [ -n "$existing_key_file" ]; then
    [ -f "$existing_key_file" ] || lifecycle::fail "age key not found at: $existing_key_file"
    # Only confirm a real overwrite; an identical key already in place is an idempotent re-apply.
    if [ -f "$key_path" ] && ! cmp -s "$existing_key_file" "$key_path"; then
      age::_confirm_overwrite "$key_path" "--existing-age-key-file"
    fi
    logging::info "age key: will install from $existing_key_file"
  elif [ -f "$key_path" ]; then
    generate=$(context::get "age.key_generate" --coerce boolean --default false --store-default)
    if [ "$generate" = "true" ]; then
      age::_confirm_overwrite "$key_path" "--generate-age-key"
      logging::info "age key: will generate a new one (overwriting existing)"
    else
      logging::info "age key: using existing $key_path"
    fi
  elif [ "$(context::get "age.key_generate" --coerce boolean --default false)" = "true" ]; then
    # Match age::install's precedence: an explicit generate request wins over the
    # manager, so the announced plan matches the action that install will take.
    logging::info "age key: will generate a new one"
  elif age::_manager_sources_key; then
    secrets::present "$_MK_SECRETS_AGE_KEY_NAME" || lifecycle::fail \
      "age key: key_source_type = secrets_manager, but the manager has no '$_MK_SECRETS_AGE_KEY_NAME' — add it as a [secrets.manager_refs] entry or by the convention name."
    logging::info "age key: will fetch from the configured secrets manager"
  else
    local generate_prompt
    # shellcheck disable=SC2059
    printf -v generate_prompt "$_AGE_GENERATE_PROMPT" "$key_path"
    generate=$(context::get "age.key_generate" --required --coerce boolean --prompt "$generate_prompt")
    [ "$generate" = "true" ] || lifecycle::fail "No age key available and no instructions were provided for generating or copying one. See --help for options."
    logging::info "age key: will generate a new one"
  fi
}

# Prompts the user to confirm overwriting an existing key, failing if they decline.
# Only called when a conflict is detected.
age::_confirm_overwrite() {
  local key_path="$1" problem_flag="$2" overwrite
  # shellcheck disable=SC2059
  printf -v "overwrite_prompt" "$_AGE_OVERWRITE_PROMPT" "$key_path"
  overwrite=$(context::get "age.key_overwrite" --required --coerce boolean --prompt "$overwrite_prompt")
  [ "$overwrite" = "true" ] || lifecycle::fail "age key not overwritten. Remove $key_path first, or omit $problem_flag to use the existing key."
}

age::install() {
  logging::step "age encryption key"
  brew::install_formula age

  local key_path existing_key_file generate
  key_path=$(config::get "module.age.key_path")
  existing_key_file=$(context::get "existing_age_key_file" || true)
  generate=$(context::get "age.key_generate" --coerce boolean --default false)
  age::_warn_source_override "$existing_key_file" "$generate"

  if input::is_dry_run; then
    age::_report_dry_run "$existing_key_file" "$generate" "$key_path"
    return 0
  fi

  local age_key_dir
  age_key_dir="$(dirname "$key_path")"
  mkdir -p "$age_key_dir"
  chmod 700 "$age_key_dir"

  if [ -n "$existing_key_file" ]; then
    age::_install_copy "$existing_key_file" "$key_path"
  elif [ "$generate" = "true" ]; then
    age::_install_generate "$key_path"
  elif [ ! -f "$key_path" ] && age::_manager_sources_key; then
    age::_install_from_manager "$key_path"
  else
    age::_install_use_existing "$key_path"
  fi
}

age::_report_dry_run() {
  local existing_key_file="$1" generate="$2" key_path="$3"
  if [ -n "$existing_key_file" ]; then
    logging::dry_run "would install age key: $existing_key_file → $key_path"
  elif [ "$generate" = "true" ]; then
    logging::dry_run "would generate new age key at $key_path"
  elif [ ! -f "$key_path" ] && age::_manager_sources_key; then
    logging::dry_run "would fetch age key from the configured secrets manager"
  else
    logging::info "age key: existing key at $key_path — no change"
  fi
}

age::_install_copy() {
  local src="$1" key_path="$2"
  cp "$src" "$key_path"
  chmod 600 "$key_path"
  logging::success "Installed age key from $src"
}

age::_install_generate() {
  local key_path="$1"
  logging::info "Generating new age key..."
  age-keygen -o "$key_path"
  chmod 600 "$key_path"
  local pubkey
  pubkey="$(age-keygen -y "$key_path")"
  logging::success "Generated new age key at $key_path"
  logging::banner warn "${MK_COLOR_BOLD}BACK UP YOUR PRIVATE KEY:${MK_COLOR_RESET} $key_path
Public key (safe to share):
  $pubkey
Loss of the private key = loss of access to encrypted blueprints."
}

age::_install_use_existing() {
  local key_path="$1"
  chmod 600 "$key_path" 2>/dev/null || true
  logging::success "Using existing age key at $key_path"
}

age::_install_from_manager() {
  local key_path="$1" reference
  reference="$(age::_reference_for_key)"
  secrets::install_secret_file "$key_path" secrets_manager::fetch "$reference" \
    || lifecycle::fail "age key: the configured secrets manager returned no value for '$reference'."
  logging::success "Installed age key from the configured secrets manager"
}

# Claims the .age extension for home sync: a decode-tier transform handled by
# age::decrypt directly.
age::file_transforms() {
  printf '%s\n' "age decode age::decrypt"
}

# age::decrypt FILE — decrypt FILE with the installed key, plaintext to stdout.
# The decryption primitive; stdout output lets callers keep plaintext off disk.
age::decrypt() {
  local file="$1" key_path
  key_path=$(config::get "module.age.key_path" --default "$AGE_KEY_PATH")
  [ -f "$key_path" ] || lifecycle::fail "age::decrypt: no age key at $key_path"
  [ -f "$file" ] || lifecycle::fail "age::decrypt: file not found: $file"
  age --decrypt --identity "$key_path" "$file"
}

# age::recipient — the public recipient (encryption target) derived from the
# installed age private key. The encrypt-side counterpart to the identity
# age::decrypt reads, so a caller can default "encrypt to this box's key" without
# handling the public half itself.
age::recipient() {
  local key_path
  key_path=$(config::get "module.age.key_path" --default "$AGE_KEY_PATH")
  [ -f "$key_path" ] || lifecycle::fail "age::recipient: no age key at $key_path"
  age-keygen -y "$key_path"
}

# age::encrypt RECIPIENT — encrypt stdin to RECIPIENT (an age public key),
# ciphertext to stdout. The encrypt primitive; stdin in / stdout out lets the
# caller keep plaintext off disk and decide where the ciphertext lands. Mirror of
# age::decrypt.
age::encrypt() {
  local recipient="$1"
  [ -n "$recipient" ] || lifecycle::fail "age::encrypt: no recipient given"
  age --encrypt --recipient "$recipient"
}

# age::is_encrypted_file FILE — true when FILE is an age-encrypted file, judged by
# its header magic (binary or ASCII-armored), not its name. Lets a caller tell an
# already-encrypted secret from plaintext before choosing to encrypt or copy it.
age::is_encrypted_file() {
  local file="$1" first
  [ -f "$file" ] || return 1
  IFS= read -r first < "$file" || true
  case "$first" in
    "age-encryption.org/v1"|"-----BEGIN AGE ENCRYPTED FILE-----") return 0 ;;
    *) return 1 ;;
  esac
}

# age::can_decrypt FILE — true when the installed identity can decrypt FILE. A
# trial decryption, plaintext discarded: age files don't reveal their recipients,
# so attempting to unwrap the file-key is the only way to confirm this key is one.
# False covers both "wrong recipient" and "no local key" — the caller phrases why.
age::can_decrypt() {
  local file="$1" key_path
  key_path=$(config::get "module.age.key_path" --default "$AGE_KEY_PATH")
  age --decrypt --identity "$key_path" "$file" >/dev/null 2>&1
}

# age::_key_source_type — the raw configured key source: "file" (copied or
# generated locally, the default) or "secrets_manager" (fetched from the active
# satisfier). A pure getter — an unrecognized value is rejected separately by
# age::assert_key_source_type, run in the main shell at the entry points, so this
# getter stays side-effect-free and safe to read from anywhere, including the
# inventory and dependency-graph subshells.
age::_key_source_type() {
  config::get "module.age.key_source_type" --default "file"
}

# age::_reference_for_key — the reference to hand secrets_manager::fetch for the
# age key: the explicit [secrets.manager_refs] age_key entry, or the bare
# convention name. A normal secrets::_reference_for consumer — the age key carries
# no reference config of its own.
age::_reference_for_key() {
  secrets::_reference_for "$_MK_SECRETS_AGE_KEY_NAME"
}

# age::_manager_sources_key — true when the age key is configured to come from the
# secrets manager (key_source_type = secrets_manager), false otherwise. A pure
# directive: whether the manager actually HOLDS the key is a separate, truthful
# question, answered by secrets::present in preflight and by the inventory — never
# assumed here. The value's validity is enforced separately by
# age::assert_key_source_type at the main-shell entry points, so this predicate
# stays side-effect-free and safe to call from the subshells that build the
# inventory (declared_secrets) and the dependency graph (requires), where an
# aborting exit would be swallowed anyway.
age::_manager_sources_key() {
  [ "$(age::_key_source_type)" = "secrets_manager" ]
}

# age::assert_key_source_type — abort on an unrecognized module.age.key_source_type.
# Run bare at the main-shell entry points so the abort actually halts; the
# predicate above stays pure precisely so it can run in the inventory and
# dependency-graph subshells, where an exit would be swallowed. This is the one
# place the value is validated where lifecycle::fail can stop the run.
age::assert_key_source_type() {
  case "$(age::_key_source_type)" in
    file|secrets_manager) ;;
    *) lifecycle::fail "age: invalid module.age.key_source_type '$(age::_key_source_type)' — expected 'file' or 'secrets_manager'." ;;
  esac
}

# age::_warn_source_override EXISTING_KEY_FILE GENERATE — warn when a runtime flag
# overrides a configured manager source: key_source_type asks for the manager, but
# --existing-age-key-file or --generate-age-key was passed, so the flag wins and
# the manager source is ignored on this machine. Advisory, not fatal — the flag
# deliberately overrides.
age::_warn_source_override() {
  local existing_key_file="$1" generate="$2"
  age::_manager_sources_key || return 0
  if [ -n "$existing_key_file" ]; then
    logging::warn "age key: key_source_type = secrets_manager, but --existing-age-key-file was given — installing that file and ignoring the manager source."
  elif [ "$generate" = "true" ]; then
    logging::warn "age key: key_source_type = secrets_manager, but --generate-age-key was given — generating a new key and ignoring the manager source."
  fi
}
