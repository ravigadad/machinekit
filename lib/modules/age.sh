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
