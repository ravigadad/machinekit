#!/usr/bin/env bats
# Tests for lib/modules/age.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/age.sh
  source "$MACHINEKIT_DIR/lib/modules/age.sh"
  AGE_KEY_PATH="$BATS_TEST_TMPDIR/age/key.txt"
  unset OPT_EXISTING_AGE_KEY_FILE
  unset MACHINEKIT_EXISTING_AGE_KEY_FILE
}

# --- age::preflight ---

@test "preflight with existing key file logs the copy plan" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key.txt"
  printf 'fake key\n' > "$keyfile"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_age_key_file"
  mktest::stub_function logging::info
  age::preflight
  MATCH="will install" mktest::assert_stub_called logging::info
}

@test "preflight calls _confirm_overwrite and logs copy plan when existing key file conflicts with destination" {
  local keyfile="$BATS_TEST_TMPDIR/provided-key.txt"
  printf 'fake key\n' > "$keyfile"
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$keyfile" mktest::stub_function context::get "existing_age_key_file"
  mktest::stub_function age::_confirm_overwrite
  mktest::stub_function logging::info
  age::preflight
  mktest::assert_stub_called age::_confirm_overwrite "$AGE_KEY_PATH" "--existing-age-key-file"
  MATCH="will install" mktest::assert_stub_called logging::info
}

@test "preflight fails when the provided key file does not exist" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/no-such-key.txt" mktest::stub_function context::get "existing_age_key_file"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::preflight
  MATCH="age key not found" mktest::assert_stub_called lifecycle::fail
}

@test "preflight logs existing plan when key is present and generate not requested" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false" "--store-default"
  mktest::stub_function logging::info
  age::preflight
  MATCH="using existing" mktest::assert_stub_called logging::info
}

@test "preflight calls _confirm_overwrite and logs generate plan when generate requested over existing key" {
  mkdir -p "$(dirname "$AGE_KEY_PATH")"
  printf 'existing key\n' > "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
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
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--required" "--coerce" "boolean" "--prompt" "$generate_prompt"
  mktest::stub_function logging::info
  age::preflight
  MATCH="generate" mktest::assert_stub_called logging::info
}

@test "preflight fails when no key exists and generation declined" {
  local generate_prompt
  # shellcheck disable=SC2059
  printf -v generate_prompt "$_AGE_GENERATE_PROMPT" "$AGE_KEY_PATH"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path" "--default" "$AGE_KEY_PATH" "--store-default"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--required" "--coerce" "boolean" "--prompt" "$generate_prompt"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! age::preflight
  MATCH="No age key" mktest::assert_stub_called lifecycle::fail
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
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path"
  STUB_OUTPUT="$src" mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  mktest::stub_function input::is_dry_run
  mktest::stub_function age::_report_dry_run
  run age::install
  [ "$status" -eq 0 ]
  mktest::assert_stub_called age::_report_dry_run "$src" "false" "$AGE_KEY_PATH"
}

@test "install with existing_key_file creates the key dir with 700 permissions and delegates to _install_copy" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path"
  STUB_OUTPUT="$src" mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
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
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_generate
  age::install
  mktest::assert_stub_called age::_install_generate "$AGE_KEY_PATH"
}

@test "install with no key file and generate=false delegates to _install_use_existing" {
  STUB_OUTPUT="$AGE_KEY_PATH" mktest::stub_function context::get "age.key_path"
  STUB_RETURN=1 mktest::stub_function context::get "existing_age_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "age.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function logging::step
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function age::_install_use_existing
  age::install
  mktest::assert_stub_called age::_install_use_existing "$AGE_KEY_PATH"
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

@test "_report_dry_run with no file and generate=false logs no change" {
  mktest::stub_function logging::info
  age::_report_dry_run "" "false" "/dest/key.txt"
  MATCH="no change" mktest::assert_stub_called logging::info
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
