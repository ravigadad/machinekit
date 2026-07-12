#!/usr/bin/env bats
# Tests for lib/modules/age.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/age.sh
  source "$MACHINEKIT_DIR/lib/modules/age.sh"
  AGE_KEY_PATH="$BATS_TEST_TMPDIR/age/key.txt"
  # Reserved name owned by secrets.sh (not sourced here); the age module reads it.
  _MK_SECRETS_AGE_KEY_NAME="age_key"
  unset OPT_EXISTING_AGE_KEY_FILE
  unset MACHINEKIT_EXISTING_AGE_KEY_FILE # hi
}

# --- age::requires ---

@test "requires the secrets_manager capability when the key is manager-sourced" {
  mktest::stub_function age::_manager_sources_key
  run age::requires
  [ "$output" = "secrets_manager" ]
}

@test "requires nothing when the key is not manager-sourced" {
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  run age::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- age::declared_secrets ---

@test "declared_secrets emits the age_key row (required, not generatable) when manager-sourced" {
  mktest::stub_function age::_manager_sources_key
  run age::declared_secrets
  [ "$output" = $'age_key\ttrue\tfalse' ]
}

@test "declared_secrets emits nothing when the key is not manager-sourced" {
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  run age::declared_secrets
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- age::preflight ---

@test "preflight with existing key file logs the copy plan" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key.txt"
  printf 'fake key\n' > "$keyfile"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_age_key_file"
  mktest::stub_function logging::info
  age::preflight
  MATCH="will install" mktest::assert_stub_called logging::info
}

@test "preflight calls _confirm_overwrite and logs copy plan when the provided key differs from the destination" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key.txt"
  printf 'fake key\n' > "$keyfile"
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_age_key_file"
  mktest::stub_function age::_confirm_overwrite
  mktest::stub_function logging::info
  age::preflight
  mktest::assert_stub_called age::_confirm_overwrite "$AGE_KEY_PATH" "--existing-age-key-file"
  MATCH="will install" mktest::assert_stub_called logging::info
}

@test "preflight skips _confirm_overwrite when the provided key is identical to the destination" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key.txt"
  printf 'same key\n' > "$keyfile"
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'same key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_age_key_file"
  mktest::stub_function age::_confirm_overwrite
  mktest::stub_function logging::info
  age::preflight
  mktest::assert_stub_not_called age::_confirm_overwrite
  MATCH="will install" mktest::assert_stub_called logging::info
}

@test "preflight fails when the provided key file does not exist" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/no-such-key.txt" mktest::stub_function context::get "existing_age_key_file"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::preflight
  MATCH="age key not found" mktest::assert_stub_called lifecycle::fail
}

@test "preflight logs existing plan when key is present and generate not requested" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false" "--store-default"
  mktest::stub_function logging::info
  age::preflight
  MATCH="using existing" mktest::assert_stub_called logging::info
}

@test "preflight calls _confirm_overwrite and logs generate plan when generate requested over existing key" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false" "--store-default"
  mktest::stub_function age::_confirm_overwrite
  mktest::stub_function logging::info
  age::preflight
  mktest::assert_stub_called age::_confirm_overwrite "$AGE_KEY_PATH" "--generate-age-key"
  MATCH="generate" mktest::assert_stub_called logging::info
}

@test "preflight logs generate plan when no key exists and generation confirmed" {
  local generate_prompt
  # shellcheck disable=SC2059
  printf -v generate_prompt "$_AGE_GENERATE_PROMPT" "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--required" "--coerce" "boolean" "--prompt" "$generate_prompt"
  mktest::stub_function logging::info
  age::preflight
  MATCH="generate" mktest::assert_stub_called logging::info
}

@test "preflight fails when no key exists and generation declined" {
  local generate_prompt
  # shellcheck disable=SC2059
  printf -v generate_prompt "$_AGE_GENERATE_PROMPT" "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--required" "--coerce" "boolean" "--prompt" "$generate_prompt"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::preflight
  MATCH="No age key" mktest::assert_stub_called lifecycle::fail
}

@test "preflight resolves via the secrets manager when no key file exists, the manager sources the key, and holds it" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function secrets::present "age_key"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function logging::info
  age::preflight
  MATCH="secrets manager" mktest::assert_stub_called logging::info
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight fails fast when the manager sources the key but does not actually hold it" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function age::_manager_sources_key
  STUB_RETURN=1 mktest::stub_function secrets::present "age_key"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::preflight
  MATCH="the manager has no 'age_key'" mktest::assert_stub_called lifecycle::fail
}

@test "preflight prefers generation over the manager when generation is requested and no key exists" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::info
  age::preflight
  MATCH="will generate" mktest::assert_stub_called logging::info
  mktest::assert_stub_not_called age::_manager_sources_key
}

# --- age::_confirm_overwrite ---

@test "_confirm_overwrite succeeds when overwrite is confirmed" {
  STUB_OUTPUT="true" mktest::stub_function context::get
  age::_confirm_overwrite "/some/key.txt" "should not fail"
}

@test "_confirm_overwrite fails with the provided message when overwrite is declined" {
  STUB_OUTPUT="false" mktest::stub_function context::get
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::_confirm_overwrite "/some/key.txt" "explicit fail message"
  MATCH="explicit fail message" mktest::assert_stub_called lifecycle::fail
}

# --- age::install ---

@test "install in dry-run delegates to _report_dry_run and returns 0" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_OUTPUT="$src" mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  mktest::stub_function input::is_dry_run
  mktest::stub_function age::_report_dry_run
  run age::install
  [ "$status" -eq 0 ]
  mktest::assert_stub_called age::_report_dry_run "$src" "false" "$AGE_KEY_PATH"
}

@test "install with existing_key_file creates the key dir with 700 permissions and delegates to _install_copy" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_OUTPUT="$src" mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_copy
  age::install
  local key_dir
  key_dir="$(dirname "$AGE_KEY_PATH")"
  [ -d "$key_dir" ]
  [ "$(mktest::file_mode "$key_dir")" = "700" ]
  mktest::assert_stub_called age::_install_copy "$src" "$AGE_KEY_PATH"
}

@test "install with generate=true delegates to _install_generate" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_generate
  age::install
  mktest::assert_stub_called age::_install_generate "$AGE_KEY_PATH"
}

@test "install with no key file, generate=false, and no secrets manager active delegates to _install_use_existing" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_use_existing
  age::install
  mktest::assert_stub_called age::_install_use_existing "$AGE_KEY_PATH"
}

@test "install with no key file, generate=false, and a secrets manager active installs from it" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_from_manager
  mktest::stub_function age::_install_use_existing
  age::install
  mktest::assert_stub_called age::_install_from_manager "$AGE_KEY_PATH"
  mktest::assert_stub_not_called age::_install_use_existing
}

@test "install does not consult the secrets manager when the key already exists on disk" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  mktest::stub_function brew::install_formula "age"
  mktest::stub_function age::_warn_source_override
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function age::_install_use_existing
  age::install
  mktest::assert_stub_called age::_install_use_existing "$AGE_KEY_PATH"
  mktest::assert_stub_not_called age::_manager_sources_key
}

# --- age::_report_dry_run ---

@test "_report_dry_run with existing key file logs the copy that would happen" {
  mktest::stub_function logging::dry_run
  age::_report_dry_run "/src/key.txt" "false" "/dest/key.txt"
  MATCH="/src/key.txt" mktest::assert_stub_called logging::dry_run
}

@test "_report_dry_run with generate=true logs that a new key would be generated" {
  mktest::stub_function logging::dry_run
  age::_report_dry_run "" "true" "/dest/key.txt"
  MATCH="generate" mktest::assert_stub_called logging::dry_run
}

@test "_report_dry_run with an existing on-disk key and generate=false logs no change" {
  local key="$BATS_TEST_TMPDIR/key.txt"
  printf 'existing\n' > "$key"
  mktest::stub_function logging::info
  age::_report_dry_run "" "false" "$key"
  MATCH="no change" mktest::assert_stub_called logging::info
}

@test "_report_dry_run with no key on disk and a manager-sourced key reports the manager fetch" {
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::dry_run
  age::_report_dry_run "" "false" "$BATS_TEST_TMPDIR/absent.txt"
  MATCH="secrets manager" mktest::assert_stub_called logging::dry_run
}

@test "_report_dry_run with no key on disk and a file source (manager does not source the key) reports no change" {
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::info
  mktest::stub_function logging::dry_run
  age::_report_dry_run "" "false" "$BATS_TEST_TMPDIR/absent.txt"
  MATCH="no change" mktest::assert_stub_called logging::info
  mktest::assert_stub_not_called logging::dry_run
}

# --- age::_install_copy ---

@test "_install_copy copies the source to the destination with 600 permissions and logs success" {
  local src="$BATS_TEST_TMPDIR/src-key.txt"
  local dest="$BATS_TEST_TMPDIR/age/key.txt"
  printf 'key content\n' > "$src"
  mkdir -p "$(dirname "$dest")"
  mktest::stub_function logging::success
  age::_install_copy "$src" "$dest"
  [ "$(cat "$dest")" = "key content" ]
  [ "$(mktest::file_mode "$dest")" = "600" ]
  mktest::assert_stub_called logging::success
}

# --- age::_install_generate ---

@test "_install_generate invokes age-keygen, sets 600 permissions, and emits a banner with the public key" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf '' > "$AGE_KEY_PATH"
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function age-keygen "-o" "$AGE_KEY_PATH"
  STUB_OUTPUT="age1fakepubkey" mktest::stub_function age-keygen "-y" "$AGE_KEY_PATH"
  mktest::stub_function logging::banner
  age::_install_generate "$AGE_KEY_PATH"
  mktest::assert_stub_called age-keygen "-o" "$AGE_KEY_PATH"
  [ "$(mktest::file_mode "$AGE_KEY_PATH")" = "600" ]
  MATCH="age1fakepubkey" mktest::assert_stub_called logging::banner
}

# --- age::_install_use_existing ---

@test "_install_use_existing sets 600 permissions on the existing key and logs success" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  mktest::stub_function logging::success
  age::_install_use_existing "$AGE_KEY_PATH"
  [ "$(mktest::file_mode "$AGE_KEY_PATH")" = "600" ]
  mktest::assert_stub_called logging::success
}

# --- age::_install_from_manager ---

@test "_install_from_manager installs the key via secrets::install_secret_file and logs success" {
  STUB_OUTPUT="age_key" mktest::stub_function age::_reference_for_key
  mktest::stub_function secrets::install_secret_file "$AGE_KEY_PATH" secrets_manager::fetch "age_key"
  mktest::stub_function logging::success
  age::_install_from_manager "$AGE_KEY_PATH"
  mktest::assert_stub_called secrets::install_secret_file "$AGE_KEY_PATH" secrets_manager::fetch "age_key"
  mktest::assert_stub_called logging::success
}

@test "_install_from_manager fails when the manager returns no value" {
  STUB_OUTPUT="age_key" mktest::stub_function age::_reference_for_key
  STUB_RETURN=1 mktest::stub_function secrets::install_secret_file
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::_install_from_manager "$AGE_KEY_PATH"
  MATCH="returned no value" mktest::assert_stub_called lifecycle::fail
}

# --- age::file_transforms ---

@test "file_transforms maps .age to the decrypt decode handler" {
  run age::file_transforms
  [ "$status" -eq 0 ]
  [ "$output" = "age decode age::decrypt" ]
}

# --- age::decrypt ---

@test "decrypt invokes age with the configured identity and emits plaintext" {
  local enc="$BATS_TEST_TMPDIR/secret.age"
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$AGE_KEY_PATH"
  printf 'ciphertext\n' > "$enc"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_OUTPUT="decrypted-secret" mktest::stub_function age "--decrypt" "--identity" "$AGE_KEY_PATH" "$enc"
  run age::decrypt "$enc"
  [ "$status" -eq 0 ]
  [ "$output" = "decrypted-secret" ]
  mktest::assert_stub_called age "--decrypt" "--identity" "$AGE_KEY_PATH" "$enc"
}

@test "decrypt fails when the age key is missing" {
  local enc="$BATS_TEST_TMPDIR/secret.age"
  printf 'ciphertext\n' > "$enc"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/no-such-key" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::decrypt "$enc"
  MATCH="no age key" mktest::assert_stub_called lifecycle::fail
}

@test "decrypt fails when the encrypted file is missing" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::decrypt "$BATS_TEST_TMPDIR/missing.age"
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

# --- age::recipient ---

@test "recipient derives the public key from the installed identity" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_OUTPUT="age1fakepubkey" mktest::stub_function age-keygen "-y" "$AGE_KEY_PATH"
  run age::recipient
  [ "$status" -eq 0 ]
  [ "$output" = "age1fakepubkey" ]
  mktest::assert_stub_called age-keygen "-y" "$AGE_KEY_PATH"
}

@test "recipient fails when the age key is missing" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::recipient
  MATCH="no age key" mktest::assert_stub_called lifecycle::fail
}

# --- age::encrypt ---

@test "encrypt pipes stdin through age to the given recipient" {
  STUB_OUTPUT="ciphertext-bytes" mktest::stub_function age "--encrypt" "--recipient" "age1fakepubkey"
  run age::encrypt age1fakepubkey <<< "plaintext-value"
  [ "$status" -eq 0 ]
  [ "$output" = "ciphertext-bytes" ]
  mktest::assert_stub_called age "--encrypt" "--recipient" "age1fakepubkey"
}

@test "encrypt fails when no recipient is given" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::encrypt ""
  MATCH="recipient" mktest::assert_stub_called lifecycle::fail
}

# --- age::is_encrypted_file ---

@test "is_encrypted_file recognizes a binary age header" {
  local file="$BATS_TEST_TMPDIR/secret.age"
  printf 'age-encryption.org/v1\n-> X25519 abc\nbody\n' > "$file"
  age::is_encrypted_file "$file"
}

@test "is_encrypted_file recognizes an ASCII-armored age header" {
  local file="$BATS_TEST_TMPDIR/secret.age"
  printf -- '-----BEGIN AGE ENCRYPTED FILE-----\nYWdl\n-----END AGE ENCRYPTED FILE-----\n' > "$file"
  age::is_encrypted_file "$file"
}

@test "is_encrypted_file rejects a plaintext file" {
  local file="$BATS_TEST_TMPDIR/plain.txt"
  printf 'just-a-secret-value\n' > "$file"
  run ! age::is_encrypted_file "$file"
}

@test "is_encrypted_file rejects a nonexistent file" {
  run ! age::is_encrypted_file "$BATS_TEST_TMPDIR/no-such-file"
}

# --- age::can_decrypt ---

@test "can_decrypt is true when the installed identity decrypts the file" {
  local file="$BATS_TEST_TMPDIR/secret.age"; : > "$file"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  mktest::stub_function age "--decrypt" "--identity" "$AGE_KEY_PATH" "$file"
  age::can_decrypt "$file"
}

@test "can_decrypt is false when the identity cannot decrypt the file" {
  local file="$BATS_TEST_TMPDIR/secret.age"; : > "$file"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function config::get "module.age.key_path" "--default" "$AGE_KEY_PATH"
  STUB_RETURN=1 mktest::stub_function age "--decrypt" "--identity" "$AGE_KEY_PATH" "$file"
  run ! age::can_decrypt "$file"
}

# --- age::_key_source_type ---

@test "_key_source_type reads module.age.key_source_type, defaulting to file" {
  STUB_OUTPUT="file" mktest::stub_function config::get "module.age.key_source_type" --default "file"
  run age::_key_source_type
  [ "$output" = "file" ]
}

@test "_key_source_type returns the configured value" {
  STUB_OUTPUT="secrets_manager" mktest::stub_function config::get "module.age.key_source_type" --default "file"
  run age::_key_source_type
  [ "$output" = "secrets_manager" ]
}

# --- age::_reference_for_key ---

@test "_reference_for_key resolves the age_key reference as a normal secrets consumer" {
  STUB_OUTPUT="RESOLVED-REF" mktest::stub_function secrets::_reference_for "age_key"
  run age::_reference_for_key
  [ "$output" = "RESOLVED-REF" ]
}

# --- age::_manager_sources_key ---

@test "_manager_sources_key is true when key_source_type is secrets_manager" {
  STUB_OUTPUT="secrets_manager" mktest::stub_function age::_key_source_type
  run age::_manager_sources_key
  [ "$status" -eq 0 ]
}

@test "_manager_sources_key is false when key_source_type is file" {
  STUB_OUTPUT="file" mktest::stub_function age::_key_source_type
  run age::_manager_sources_key
  [ "$status" -ne 0 ]
}

# --- age::assert_key_source_type ---

@test "assert_key_source_type accepts file" {
  STUB_OUTPUT="file" mktest::stub_function age::_key_source_type
  age::assert_key_source_type
}

@test "assert_key_source_type accepts secrets_manager" {
  STUB_OUTPUT="secrets_manager" mktest::stub_function age::_key_source_type
  age::assert_key_source_type
}

@test "assert_key_source_type aborts on an unrecognized value — fires in the main shell" {
  STUB_OUTPUT="vault" mktest::stub_function age::_key_source_type
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run age::assert_key_source_type
  [ "$status" -ne 0 ]
  MATCH="invalid module.age.key_source_type 'vault'" mktest::assert_stub_called lifecycle::fail
}

# --- age::_warn_source_override ---

@test "_warn_source_override warns when a manager source is overridden by an existing-key file" {
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::warn
  age::_warn_source_override "/some/key.txt" "false"
  MATCH="--existing-age-key-file" mktest::assert_stub_called logging::warn
}

@test "_warn_source_override warns when a manager source is overridden by --generate-age-key" {
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::warn
  age::_warn_source_override "" "true"
  MATCH="--generate-age-key" mktest::assert_stub_called logging::warn
}

@test "_warn_source_override is silent when the key source is not the manager (nothing to override)" {
  STUB_RETURN=1 mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::warn
  age::_warn_source_override "/some/key.txt" "true"
  mktest::assert_stub_not_called logging::warn
}

@test "_warn_source_override is silent when a manager source is used with no overriding flag" {
  mktest::stub_function age::_manager_sources_key
  mktest::stub_function logging::warn
  age::_warn_source_override "" "false"
  mktest::assert_stub_not_called logging::warn
}
