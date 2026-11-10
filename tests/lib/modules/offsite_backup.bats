#!/usr/bin/env bats
# Tests for lib/modules/offsite_backup.sh — the install-time wiring of the
# scheduled offsite copies. The restic driving itself is tested in
# offsite_backup/restic_run.bats; the launchd/systemd load is service.sh's
# runtime-unverified seam and is stubbed here.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/offsite_backup.sh
  source "$MACHINEKIT_DIR/lib/modules/offsite_backup.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
}

# One well-formed repository entry, used wherever the entry's own content is
# incidental to what the test is checking.
ENTRY='{"name":"fake_repo","repository":"fake:repository","paths":{"dumps":{"path":"/fake/dumps"}}}'

# --- requires ---

@test "requires pipes its declared secrets through the backend-requirements helper" {
  STUB_OUTPUT=$'offsite_backup/fake_repo/repository_password\ttrue\tfalse' \
    mktest::stub_function offsite_backup::declared_secrets
  secrets::declared_backend_requirements() { cat > "$BATS_TEST_TMPDIR/br.stdin"; printf 'secrets_manager\n'; }
  run offsite_backup::requires
  [ "$status" -eq 0 ]
  [ "$output" = "secrets_manager" ]
  # The module hands its declared-secret rows to the shared classifier verbatim.
  [ "$(cat "$BATS_TEST_TMPDIR/br.stdin")" = $'offsite_backup/fake_repo/repository_password\ttrue\tfalse' ]
}

@test "requires nothing when no repositories are configured (no secrets declared)" {
  mktest::stub_function offsite_backup::declared_secrets
  secrets::declared_backend_requirements() { cat > /dev/null; }
  run offsite_backup::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- declared_secrets ---

@test "declared_secrets namespaces a password and a credentials secret per repository" {
  STUB_OUTPUT='[{"name":"first_repo"},{"name":"second_repo"}]' \
    mktest::stub_function offsite_backup::_repositories
  run offsite_backup::declared_secrets
  [ "$status" -eq 0 ]
  # Each repository has its own password and credentials: two destinations mean
  # two providers and two encryption keys, never one shared pair.
  [ "$output" = $'offsite_backup/first_repo/repository_password\ttrue\tfalse
offsite_backup/first_repo/credentials\tfalse\tfalse
offsite_backup/second_repo/repository_password\ttrue\tfalse
offsite_backup/second_repo/credentials\tfalse\tfalse' ]
}

@test "declared_secrets declares nothing when no repositories are configured" {
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories
  run offsite_backup::declared_secrets
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- preflight ---

@test "preflight validates the repository set, then each repository" {
  STUB_OUTPUT="[$ENTRY]" mktest::stub_function offsite_backup::_repositories
  mktest::stub_function offsite_backup::_validate_repositories "[$ENTRY]"
  mktest::stub_function offsite_backup::_validate_repository "$ENTRY"
  offsite_backup::preflight
  mktest::assert_stub_called_in_order offsite_backup::_validate_repositories "[$ENTRY]"
  mktest::assert_stub_called_in_order offsite_backup::_validate_repository "$ENTRY"
}

@test "preflight validates every configured repository" {
  STUB_OUTPUT='[{"name":"first_repo"},{"name":"second_repo"}]' \
    mktest::stub_function offsite_backup::_repositories
  mktest::stub_function offsite_backup::_validate_repositories
  mktest::stub_function offsite_backup::_validate_repository
  offsite_backup::preflight
  mktest::assert_stub_called offsite_backup::_validate_repository '{"name":"first_repo"}'
  mktest::assert_stub_called offsite_backup::_validate_repository '{"name":"second_repo"}'
}

@test "preflight is a no-op when no repositories are configured" {
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories
  mktest::stub_function offsite_backup::_validate_repositories
  mktest::stub_function offsite_backup::_validate_repository
  offsite_backup::preflight
  mktest::assert_stub_not_called offsite_backup::_validate_repositories
  mktest::assert_stub_not_called offsite_backup::_validate_repository
}

# --- _validate_repository ---

@test "_validate_repository checks its paths, its secrets, and both of its schedules" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT='[{"path":"/fake/dumps"}]' mktest::stub_function offsite_backup::_paths "$ENTRY"
  STUB_OUTPUT="30 3 * * *" mktest::stub_function offsite_backup::_schedule "$ENTRY"
  STUB_OUTPUT="0 4 * * 0" mktest::stub_function offsite_backup::_check_schedule "$ENTRY"
  mktest::stub_function offsite_backup::_validate_paths '[{"path":"/fake/dumps"}]' "fake_repo"
  mktest::stub_function offsite_backup::_validate_secrets "fake_repo"
  mktest::stub_function service::validate_cron "30 3 * * *"
  mktest::stub_function service::validate_cron "0 4 * * 0"
  offsite_backup::_validate_repository "$ENTRY"
  mktest::assert_stub_called offsite_backup::_validate_paths '[{"path":"/fake/dumps"}]' "fake_repo"
  mktest::assert_stub_called offsite_backup::_validate_secrets "fake_repo"
  mktest::assert_stub_called service::validate_cron "30 3 * * *"
  mktest::assert_stub_called service::validate_cron "0 4 * * 0"
}

# --- install ---

@test "install installs restic and the run script once, then wires each repository" {
  STUB_OUTPUT='[{"name":"first_repo"},{"name":"second_repo"}]' \
    mktest::stub_function offsite_backup::_repositories
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function brew::install_formula restic
  mktest::stub_function offsite_backup::_install_run_script
  mktest::stub_function offsite_backup::_install_repository
  offsite_backup::install
  mktest::assert_stub_called brew::install_formula restic
  # One script serves every repository, so it is laid down once rather than
  # per repository — and before any of them, since the repository step drives it.
  TIMES=1 mktest::assert_stub_called_in_order offsite_backup::_install_run_script
  mktest::assert_stub_called_in_order offsite_backup::_install_repository '{"name":"first_repo"}'
  mktest::assert_stub_called_in_order offsite_backup::_install_repository '{"name":"second_repo"}'
}

@test "install is a no-op when no repositories are configured, not even installing restic" {
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories
  mktest::stub_function brew::install_formula
  mktest::stub_function offsite_backup::_install_repository
  offsite_backup::install
  mktest::assert_stub_not_called brew::install_formula
  mktest::assert_stub_not_called offsite_backup::_install_repository
  mktest::assert_stub_called logging::debug
}

@test "install writes no secrets and schedules nothing in dry-run" {
  STUB_OUTPUT="[$ENTRY]" mktest::stub_function offsite_backup::_repositories
  mktest::stub_function input::is_dry_run
  mktest::stub_function brew::install_formula restic
  mktest::stub_function offsite_backup::_install_run_script
  mktest::stub_function offsite_backup::_install_repository
  offsite_backup::install
  mktest::assert_stub_not_called offsite_backup::_install_run_script
  # A dry run must not create anything at any remote, consented or not.
  mktest::assert_stub_not_called offsite_backup::_install_repository
  mktest::assert_stub_called logging::dry_run
}

# --- _install_repository ---

@test "_install_repository lays down its secrets and manifest, creates it, then schedules both services" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT='[{"path":"/fake/dumps"}]' mktest::stub_function offsite_backup::_paths "$ENTRY"
  mktest::stub_function offsite_backup::_install_secret_files "fake_repo"
  mktest::stub_function offsite_backup::_write_manifest "fake_repo" '[{"path":"/fake/dumps"}]'
  mktest::stub_function offsite_backup::_ensure_repository "$ENTRY"
  mktest::stub_function offsite_backup::_install_backup_service "$ENTRY"
  mktest::stub_function offsite_backup::_install_check_service "$ENTRY"
  offsite_backup::_install_repository "$ENTRY"
  mktest::assert_stub_called offsite_backup::_install_backup_service "$ENTRY"
  mktest::assert_stub_called offsite_backup::_install_check_service "$ENTRY"
  # Order is the contract: creating the repository drives the run script with
  # this repository's secret files, so those must be on disk first.
  mktest::assert_stub_called_in_order offsite_backup::_install_secret_files "fake_repo"
  mktest::assert_stub_called_in_order offsite_backup::_ensure_repository "$ENTRY"
}

# --- postflight_info / postflight_instructions ---

@test "postflight_info reports each repository's paths, schedule, and retention" {
  STUB_OUTPUT='[{"name":"fake_repo","repository":"fake:repository"}]' \
    mktest::stub_function offsite_backup::_repositories
  STUB_OUTPUT='[{"path":"~/dumps"}]' \
    mktest::stub_function offsite_backup::_paths '{"name":"fake_repo","repository":"fake:repository"}'
  STUB_OUTPUT="30 3 * * *" mktest::stub_function offsite_backup::_schedule
  STUB_OUTPUT="0 4 * * 0" mktest::stub_function offsite_backup::_check_schedule
  STUB_OUTPUT="7" mktest::stub_function offsite_backup::_keep_daily
  STUB_OUTPUT="4" mktest::stub_function offsite_backup::_keep_weekly
  STUB_OUTPUT="12" mktest::stub_function offsite_backup::_keep_monthly
  run offsite_backup::postflight_info
  [[ "$output" == *"~/dumps"* ]]
  [[ "$output" == *"fake:repository"* ]]
  [[ "$output" == *"30 3 * * *"* ]]
  # Retention deletes remote history, so what it is must be visible, not buried
  # in the defaults.
  [[ "$output" == *"7 daily"* ]]
  [[ "$output" == *"4 weekly"* ]]
  [[ "$output" == *"12 monthly"* ]]
  [[ "$output" == *"0 4 * * 0"* ]]
}

@test "postflight_info names the repository each line belongs to" {
  STUB_OUTPUT='[{"name":"first_repo","repository":"fake:one"},{"name":"second_repo","repository":"fake:two"}]' \
    mktest::stub_function offsite_backup::_repositories
  STUB_OUTPUT='[{"path":"/fake/a"}]' \
    mktest::stub_function offsite_backup::_paths '{"name":"first_repo","repository":"fake:one"}'
  STUB_OUTPUT='[{"path":"/fake/b"}]' \
    mktest::stub_function offsite_backup::_paths '{"name":"second_repo","repository":"fake:two"}'
  STUB_OUTPUT="30 3 * * *" mktest::stub_function offsite_backup::_schedule
  STUB_OUTPUT="0 4 * * 0" mktest::stub_function offsite_backup::_check_schedule
  STUB_OUTPUT="7" mktest::stub_function offsite_backup::_keep_daily
  STUB_OUTPUT="4" mktest::stub_function offsite_backup::_keep_weekly
  STUB_OUTPUT="12" mktest::stub_function offsite_backup::_keep_monthly
  run offsite_backup::postflight_info
  [[ "$output" == *"first_repo"* ]]
  [[ "$output" == *"second_repo"* ]]
}

@test "postflight_info emits nothing when no repositories are configured" {
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories
  run offsite_backup::postflight_info
  [ -z "$output" ]
}

@test "postflight_instructions names only the repositories that still do not exist" {
  STUB_OUTPUT='[{"name":"absent_repo","repository":"fake:absent"},{"name":"present_repo","repository":"fake:present"}]' \
    mktest::stub_function offsite_backup::_repositories
  STUB_OUTPUT="false" mktest::stub_function offsite_backup::_repository_ready "absent_repo"
  STUB_OUTPUT="true" mktest::stub_function offsite_backup::_repository_ready "present_repo"
  run offsite_backup::postflight_instructions
  [[ "$output" == *"fake:absent"* ]]
  [[ "$output" != *"fake:present"* ]]
  [[ "$output" == *"MACHINEKIT_OFFSITE_BACKUP_INIT_REPOSITORY"* ]]
}

@test "postflight_instructions stays quiet once every repository exists" {
  STUB_OUTPUT='[{"name":"fake_repo","repository":"fake:repository"}]' \
    mktest::stub_function offsite_backup::_repositories
  STUB_OUTPUT="true" mktest::stub_function offsite_backup::_repository_ready "fake_repo"
  run offsite_backup::postflight_instructions
  [ -z "$output" ]
}

@test "postflight_instructions emits nothing when no repositories are configured" {
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories
  run offsite_backup::postflight_instructions
  [ -z "$output" ]
}

# --- _validate_repositories / _repositories_shape_error ---

@test "_validate_repositories passes a well-formed repository set" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  STUB_OUTPUT="" mktest::stub_function offsite_backup::_repositories_shape_error "[$ENTRY]"
  offsite_backup::_validate_repositories "[$ENTRY]"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_repositories fails with the problem the shape check found" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  STUB_OUTPUT="some shape problem" mktest::stub_function offsite_backup::_repositories_shape_error
  run ! offsite_backup::_validate_repositories '[{}]'
  MATCH="some shape problem" mktest::assert_stub_called lifecycle::fail
}

@test "_repositories_shape_error finds nothing wrong with a well-formed set" {
  run offsite_backup::_repositories_shape_error "[$ENTRY]"
  [ -z "$output" ]
}

@test "_repositories_shape_error reports an entry with no name" {
  run offsite_backup::_repositories_shape_error \
    '[{"repository":"fake:repository","paths":[{"path":"/fake/dumps"}]}]'
  [[ "$output" == *"name"* ]]
}

@test "_repositories_shape_error rejects a name that is not snake_case" {
  # The name becomes a secret namespace, a filename, a service label, and part of
  # an environment-variable name, so anything outside [a-z0-9_] would break one of
  # those rather than fail here.
  run offsite_backup::_repositories_shape_error \
    '[{"name":"My-Repo","repository":"fake:repository","paths":[{"path":"/fake/dumps"}]}]'
  [[ "$output" == *"lowercase"* ]]
}

@test "_repositories_shape_error reports an entry with no repository string" {
  run offsite_backup::_repositories_shape_error \
    '[{"name":"fake_repo","paths":[{"path":"/fake/dumps"}]}]'
  [[ "$output" == *"repository"* ]]
}

# --- _validate_paths ---

@test "_validate_paths passes a well-formed path set" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  offsite_backup::_validate_paths '[{"path":"/fake/dumps"},{"path":"/fake/other","max_age_hours":36}]' "fake_repo"
  mktest::assert_stub_not_called lifecycle::fail
}

# Checked here rather than with the repository set, because a path a machine type
# turned off leaves nothing to back up just as surely as one never written.
@test "_validate_paths fails, naming the repository, when it has no enabled paths" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! offsite_backup::_validate_paths "" "fake_repo"
  MATCH="fake_repo.*at least one" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_paths fails when an entry has no path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! offsite_backup::_validate_paths '[{"max_age_hours":36}]' "fake_repo"
  MATCH="needs a path" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_paths fails on a non-numeric max_age_hours" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! offsite_backup::_validate_paths '[{"path":"/fake/dumps","max_age_hours":"a while"}]' "fake_repo"
  MATCH="max_age_hours" mktest::assert_stub_called lifecycle::fail
}

# --- _validate_secrets ---

@test "_validate_secrets passes when the repository's password secret exists" {
  STUB_OUTPUT="offsite_backup/fake_repo/repository_password" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" repository_password
  mktest::stub_function secrets::present "offsite_backup/fake_repo/repository_password"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  offsite_backup::_validate_secrets "fake_repo"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_secrets fails when the repository's password secret is missing" {
  STUB_OUTPUT="offsite_backup/fake_repo/repository_password" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" repository_password
  STUB_RETURN=1 mktest::stub_function secrets::present "offsite_backup/fake_repo/repository_password"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! offsite_backup::_validate_secrets "fake_repo"
  MATCH="repository_password" mktest::assert_stub_called lifecycle::fail
}

# --- _install_secret_files ---

@test "_install_secret_files installs the password and the credentials when both resolve" {
  STUB_OUTPUT="offsite_backup/fake_repo/repository_password" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" repository_password
  STUB_OUTPUT="offsite_backup/fake_repo/credentials" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" credentials
  STUB_OUTPUT="/fake/password" mktest::stub_function offsite_backup::_password_file_path "fake_repo"
  STUB_OUTPUT="/fake/credentials" mktest::stub_function offsite_backup::_credentials_file_path "fake_repo"
  mktest::stub_function secrets::present "offsite_backup/fake_repo/credentials"
  mktest::stub_function offsite_backup::_write_secret_file "/fake/password" "offsite_backup/fake_repo/repository_password"
  mktest::stub_function offsite_backup::_write_secret_file "/fake/credentials" "offsite_backup/fake_repo/credentials"
  offsite_backup::_install_secret_files "fake_repo"
  mktest::assert_stub_called offsite_backup::_write_secret_file "/fake/password" "offsite_backup/fake_repo/repository_password"
  mktest::assert_stub_called offsite_backup::_write_secret_file "/fake/credentials" "offsite_backup/fake_repo/credentials"
}

@test "_install_secret_files skips the credentials when no secret holds them" {
  # A local or sftp repository needs no backend credentials; the run script
  # tolerates the file's absence.
  STUB_OUTPUT="offsite_backup/fake_repo/repository_password" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" repository_password
  STUB_OUTPUT="offsite_backup/fake_repo/credentials" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" credentials
  STUB_OUTPUT="/fake/password" mktest::stub_function offsite_backup::_password_file_path "fake_repo"
  STUB_OUTPUT="/fake/credentials" mktest::stub_function offsite_backup::_credentials_file_path "fake_repo"
  STUB_RETURN=1 mktest::stub_function secrets::present "offsite_backup/fake_repo/credentials"
  mktest::stub_function offsite_backup::_write_secret_file "/fake/password" "offsite_backup/fake_repo/repository_password"
  offsite_backup::_install_secret_files "fake_repo"
  mktest::assert_stub_not_called offsite_backup::_write_secret_file "/fake/credentials" "offsite_backup/fake_repo/credentials"
}

@test "_install_secret_files fails when the repository password resolves to nothing" {
  STUB_OUTPUT="offsite_backup/fake_repo/repository_password" \
    mktest::stub_function offsite_backup::_secret_name "fake_repo" repository_password
  STUB_OUTPUT="/fake/password" mktest::stub_function offsite_backup::_password_file_path "fake_repo"
  STUB_RETURN=1 mktest::stub_function offsite_backup::_write_secret_file
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! offsite_backup::_install_secret_files "fake_repo"
  MATCH="no value resolved" mktest::assert_stub_called lifecycle::fail
}

# --- _write_secret_file ---

@test "_write_secret_file creates a 700 dir and installs the resolved secret" {
  local dest="$BATS_TEST_TMPDIR/secrets/fake_repo/repository_password"
  mktest::stub_function secrets::install_secret_file "$dest" secrets::resolve "fake/secret"
  offsite_backup::_write_secret_file "$dest" "fake/secret"
  [ "$(mktest::file_mode "$BATS_TEST_TMPDIR/secrets/fake_repo")" = "700" ]
  mktest::assert_stub_called secrets::install_secret_file "$dest" secrets::resolve "fake/secret"
}

# --- _write_manifest ---

@test "_write_manifest writes a row per path into the repository's own manifest" {
  local manifest="$BATS_TEST_TMPDIR/out/manifest-fake_repo.tsv"
  STUB_OUTPUT="$manifest" mktest::stub_function offsite_backup::_manifest_path "fake_repo"
  STUB_OUTPUT="manifest-row" mktest::stub_function offsite_backup::_manifest_row
  offsite_backup::_write_manifest "fake_repo" '[{"path":"/fake/a"},{"path":"/fake/b"}]'
  mktest::assert_stub_called offsite_backup::_manifest_row '{"path":"/fake/a"}'
  mktest::assert_stub_called offsite_backup::_manifest_row '{"path":"/fake/b"}'
  [ "$(grep -c 'manifest-row' "$manifest")" -eq 2 ]
}

# --- _manifest_row ---

@test "_manifest_row emits the path with its staleness deadline" {
  run offsite_backup::_manifest_row '{"path":"/fake/dumps","max_age_hours":36}'
  [ "$output" = "$(printf '/fake/dumps\t36')" ]
}

@test "_manifest_row emits an empty deadline when the path sets none" {
  run offsite_backup::_manifest_row '{"path":"/fake/dumps"}'
  [ "$output" = "$(printf '/fake/dumps\t')" ]
}

@test "_manifest_row expands a leading ~ in the path" {
  run offsite_backup::_manifest_row '{"path":"~/dumps"}'
  [ "$output" = "$(printf '%s/dumps\t' "$HOME")" ]
}

# --- _install_run_script ---

@test "_install_run_script installs the real script as executable" {
  local dest="$BATS_TEST_TMPDIR/install/restic_run.sh"
  STUB_OUTPUT="$dest" mktest::stub_function offsite_backup::_run_script_path
  offsite_backup::_install_run_script
  [ -x "$dest" ]
  grep -q "MK_OFFSITE_BACKUP_MODE" "$dest"
}

# --- _ensure_repository ---

@test "_ensure_repository asks for no consent and creates nothing when the repository is already there" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  mktest::stub_function offsite_backup::_repository_reachable "$ENTRY"
  mktest::stub_function offsite_backup::_init_consented
  mktest::stub_function offsite_backup::_initialize_repository
  mktest::stub_function context::set "offsite_backup.repositories.fake_repo.ready" true
  offsite_backup::_ensure_repository "$ENTRY"
  mktest::assert_stub_not_called offsite_backup::_init_consented
  mktest::assert_stub_not_called offsite_backup::_initialize_repository
  mktest::assert_stub_called context::set "offsite_backup.repositories.fake_repo.ready" true
}

@test "_ensure_repository creates the repository once consent is given, and records it ready" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="fake:repository" mktest::stub_function offsite_backup::_repository "$ENTRY"
  STUB_RETURN=1 mktest::stub_function offsite_backup::_repository_reachable "$ENTRY"
  mktest::stub_function offsite_backup::_init_consented "fake:repository"
  mktest::stub_function offsite_backup::_initialize_repository "$ENTRY"
  mktest::stub_function context::set "offsite_backup.repositories.fake_repo.ready" true
  offsite_backup::_ensure_repository "$ENTRY"
  mktest::assert_stub_called offsite_backup::_initialize_repository "$ENTRY"
  mktest::assert_stub_called context::set "offsite_backup.repositories.fake_repo.ready" true
}

@test "_ensure_repository creates nothing without consent, warns, and records it not ready" {
  # Creating a repository writes to the remote, so an unconsented apply must
  # leave the destination untouched and say why the scheduled runs will fail.
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="fake:repository" mktest::stub_function offsite_backup::_repository "$ENTRY"
  STUB_RETURN=1 mktest::stub_function offsite_backup::_repository_reachable "$ENTRY"
  STUB_RETURN=1 mktest::stub_function offsite_backup::_init_consented "fake:repository"
  mktest::stub_function offsite_backup::_initialize_repository
  mktest::stub_function context::set "offsite_backup.repositories.fake_repo.ready" false
  offsite_backup::_ensure_repository "$ENTRY"
  mktest::assert_stub_not_called offsite_backup::_initialize_repository
  mktest::assert_stub_called logging::warn
  mktest::assert_stub_called context::set "offsite_backup.repositories.fake_repo.ready" false
}

# --- _init_consented / _repository_reachable / _initialize_repository ---

@test "_init_consented reads the per-run consent signal, naming the repository in its prompt" {
  STUB_OUTPUT="true" mktest::stub_function context::get \
    "offsite_backup.init_repository" "--default" false "--coerce" boolean \
    "--prompt" "Create any declared restic repository that does not exist yet, starting with fake:repository? (y/n)"
  offsite_backup::_init_consented "fake:repository"
}

@test "_init_consented is false when the consent signal is absent" {
  STUB_OUTPUT="false" mktest::stub_function context::get
  run ! offsite_backup::_init_consented "fake:repository"
}

@test "_repository_reachable asks the run script, silently" {
  mktest::stub_function offsite_backup::_run_script_mode probe "$ENTRY"
  offsite_backup::_repository_reachable "$ENTRY"
  mktest::assert_stub_called offsite_backup::_run_script_mode probe "$ENTRY"
}

@test "_initialize_repository drives the run script's init mode" {
  mktest::stub_function offsite_backup::_run_script_mode init "$ENTRY"
  offsite_backup::_initialize_repository "$ENTRY"
  mktest::assert_stub_called offsite_backup::_run_script_mode init "$ENTRY"
}

# --- _run_script_mode ---

@test "_run_script_mode runs the installed script with the mode and the repository's own env" {
  local script="$BATS_TEST_TMPDIR/restic_run.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$MK_OFFSITE_BACKUP_MODE" "\${FAKE_COMMON:-}"
EOF
  chmod +x "$script"
  STUB_OUTPUT="$script" mktest::stub_function offsite_backup::_run_script_path
  STUB_OUTPUT="FAKE_COMMON=common-value" mktest::stub_function offsite_backup::_common_service_env "$ENTRY"
  run offsite_backup::_run_script_mode "fake-mode" "$ENTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'fake-mode\ncommon-value')" ]
}

# --- _common_service_env ---

@test "_common_service_env pins the notify hook, the binary, and this repository's location and secret paths" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="/n/notify" mktest::stub_function offsite_backup::_notify "$ENTRY"
  STUB_OUTPUT="/b/restic" mktest::stub_function offsite_backup::_restic_path
  STUB_OUTPUT="fake:repository" mktest::stub_function offsite_backup::_repository "$ENTRY"
  STUB_OUTPUT="/c/fake_repo/password" mktest::stub_function offsite_backup::_password_file_path "fake_repo"
  STUB_OUTPUT="/c/fake_repo/credentials" mktest::stub_function offsite_backup::_credentials_file_path "fake_repo"
  run offsite_backup::_common_service_env "$ENTRY"
  # Secret file PATHS, never their values: a launchd plist is readable at rest.
  [ "$output" = "$(printf '%s\n' \
    "MK_OFFSITE_BACKUP_NOTIFY=/n/notify" \
    "MK_OFFSITE_BACKUP_RESTIC=/b/restic" \
    "MK_OFFSITE_BACKUP_REPOSITORY=fake:repository" \
    "MK_OFFSITE_BACKUP_PASSWORD_FILE=/c/fake_repo/password" \
    "MK_OFFSITE_BACKUP_CREDENTIALS_FILE=/c/fake_repo/credentials")" ]
}

# --- _install_backup_service / _install_check_service ---

@test "_install_backup_service schedules the run script in backup mode with this repository's keep policy" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="offsite-backup-fake-repo" mktest::stub_function offsite_backup::_service_label "fake_repo"
  STUB_OUTPUT="/s/restic_run.sh" mktest::stub_function offsite_backup::_run_script_path
  STUB_OUTPUT="30 3 * * *" mktest::stub_function offsite_backup::_schedule "$ENTRY"
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function offsite_backup::_manifest_path "fake_repo"
  STUB_OUTPUT="COMMON=env" mktest::stub_function offsite_backup::_common_service_env "$ENTRY"
  STUB_OUTPUT="7" mktest::stub_function offsite_backup::_keep_daily "$ENTRY"
  STUB_OUTPUT="4" mktest::stub_function offsite_backup::_keep_weekly "$ENTRY"
  STUB_OUTPUT="12" mktest::stub_function offsite_backup::_keep_monthly "$ENTRY"
  mktest::stub_function service::install_calendar \
    "offsite-backup-fake-repo" "/s/restic_run.sh" "30 3 * * *" \
    "MK_OFFSITE_BACKUP_MODE=backup" "COMMON=env" \
    "MK_OFFSITE_BACKUP_MANIFEST=/m/manifest.tsv" \
    "MK_OFFSITE_BACKUP_KEEP_DAILY=7" \
    "MK_OFFSITE_BACKUP_KEEP_WEEKLY=4" \
    "MK_OFFSITE_BACKUP_KEEP_MONTHLY=12"
  offsite_backup::_install_backup_service "$ENTRY"
  mktest::assert_stub_called service::install_calendar \
    "offsite-backup-fake-repo" "/s/restic_run.sh" "30 3 * * *" \
    "MK_OFFSITE_BACKUP_MODE=backup" "COMMON=env" \
    "MK_OFFSITE_BACKUP_MANIFEST=/m/manifest.tsv" \
    "MK_OFFSITE_BACKUP_KEEP_DAILY=7" \
    "MK_OFFSITE_BACKUP_KEEP_WEEKLY=4" \
    "MK_OFFSITE_BACKUP_KEEP_MONTHLY=12"
}

@test "_install_check_service schedules the same script in check mode on this repository's own cadence" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="offsite-backup-fake-repo" mktest::stub_function offsite_backup::_service_label "fake_repo"
  STUB_OUTPUT="/s/restic_run.sh" mktest::stub_function offsite_backup::_run_script_path
  STUB_OUTPUT="0 4 * * 0" mktest::stub_function offsite_backup::_check_schedule "$ENTRY"
  STUB_OUTPUT="COMMON=env" mktest::stub_function offsite_backup::_common_service_env "$ENTRY"
  STUB_OUTPUT="false" mktest::stub_function offsite_backup::_check_read_data "$ENTRY"
  mktest::stub_function service::install_calendar \
    "offsite-backup-fake-repo-check" "/s/restic_run.sh" "0 4 * * 0" \
    "MK_OFFSITE_BACKUP_MODE=check" "COMMON=env" \
    "MK_OFFSITE_BACKUP_READ_DATA=false"
  offsite_backup::_install_check_service "$ENTRY"
  mktest::assert_stub_called service::install_calendar \
    "offsite-backup-fake-repo-check" "/s/restic_run.sh" "0 4 * * 0" \
    "MK_OFFSITE_BACKUP_MODE=check" "COMMON=env" \
    "MK_OFFSITE_BACKUP_READ_DATA=false"
}

# --- _repositories / per-entry accessors ---

@test "_repositories returns the configured repositories, each key filling the name" {
  STUB_OUTPUT="the-repositories" mktest::stub_function config::entries "module.offsite_backup.repositories" "name"
  run offsite_backup::_repositories
  [ "$output" = "the-repositories" ]
}

@test "_name reads the repository's name" {
  run offsite_backup::_name "$ENTRY"
  [ "$output" = "fake_repo" ]
}

@test "_repository reads the repository's destination string" {
  run offsite_backup::_repository "$ENTRY"
  [ "$output" = "fake:repository" ]
}

@test "_paths reads the enabled entries of the repository's own paths collection" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name "$ENTRY"
  STUB_OUTPUT="the-paths" mktest::stub_function config::entries_from_json \
    '{"dumps":{"path":"/fake/dumps"}}' "offsite_backup repository 'fake_repo' paths"
  run offsite_backup::_paths "$ENTRY"
  [ "$output" = "the-paths" ]
}

@test "_paths reads an empty collection when the repository declares none" {
  STUB_OUTPUT="fake_repo" mktest::stub_function offsite_backup::_name '{"name":"fake_repo"}'
  STUB_OUTPUT="" mktest::stub_function config::entries_from_json '{}' "offsite_backup repository 'fake_repo' paths"
  run offsite_backup::_paths '{"name":"fake_repo"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- _repository_setting (the entry-beats-module cascade) ---

@test "_repository_setting prefers the repository's own value over the module default" {
  run offsite_backup::_repository_setting '{"keep_daily":30}' keep_daily "7"
  [ "$output" = "30" ]
}

@test "_repository_setting falls back to the module default when the repository omits the key" {
  run offsite_backup::_repository_setting '{"name":"fake_repo"}' keep_daily "7"
  [ "$output" = "7" ]
}

# --- settings (each resolving its own module default, then the cascade) ---

@test "_schedule cascades the repository over the module default, which defaults to nightly" {
  STUB_OUTPUT="0 5 * * *" mktest::stub_function config::get \
    "module.offsite_backup.schedule" "--default" "30 3 * * *"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" schedule "0 5 * * *"
  run offsite_backup::_schedule "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_check_schedule defaults to a weekly verification" {
  STUB_OUTPUT="0 6 * * 1" mktest::stub_function config::get \
    "module.offsite_backup.check_schedule" "--default" "0 4 * * 0"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" check_schedule "0 6 * * 1"
  run offsite_backup::_check_schedule "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_keep_daily defaults to 7" {
  STUB_OUTPUT="14" mktest::stub_function config::get \
    "module.offsite_backup.keep_daily" "--default" "7"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" keep_daily "14"
  run offsite_backup::_keep_daily "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_keep_weekly defaults to 4" {
  STUB_OUTPUT="8" mktest::stub_function config::get \
    "module.offsite_backup.keep_weekly" "--default" "4"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" keep_weekly "8"
  run offsite_backup::_keep_weekly "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_keep_monthly defaults to 12" {
  STUB_OUTPUT="24" mktest::stub_function config::get \
    "module.offsite_backup.keep_monthly" "--default" "12"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" keep_monthly "24"
  run offsite_backup::_keep_monthly "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_check_read_data defaults to false, keeping the expensive verification opt-in" {
  STUB_OUTPUT="true" mktest::stub_function config::get \
    "module.offsite_backup.check_read_data" "--default" "false" "--coerce" "boolean"
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" check_read_data "true"
  run offsite_backup::_check_read_data "$ENTRY"
  [ "$output" = "from-cascade" ]
}

@test "_notify defaults to empty" {
  STUB_OUTPUT="" mktest::stub_function config::get "module.offsite_backup.notify" "--default" ""
  STUB_OUTPUT="from-cascade" mktest::stub_function offsite_backup::_repository_setting \
    "$ENTRY" notify ""
  run offsite_backup::_notify "$ENTRY"
  [ "$output" = "from-cascade" ]
}

# --- names + paths ---

@test "_secret_name namespaces a secret under its repository" {
  run offsite_backup::_secret_name "fake_repo" repository_password
  [ "$output" = "offsite_backup/fake_repo/repository_password" ]
}

@test "_service_label dashes the repository name so the unit reads as one word" {
  # The name is snake_case config; launchd labels and systemd units read as
  # dash-separated, and service.sh namespaces whatever it is handed.
  run offsite_backup::_service_label "fake_repo"
  [ "$output" = "offsite-backup-fake-repo" ]
}

@test "_repository_ready reads the outcome install recorded for that repository" {
  STUB_OUTPUT="true" mktest::stub_function context::get \
    "offsite_backup.repositories.fake_repo.ready" "--default" false
  run offsite_backup::_repository_ready "fake_repo"
  [ "$output" = "true" ]
}

@test "_restic_path resolves the restic on PATH" {
  local fakebin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\n' > "$fakebin/restic"
  chmod +x "$fakebin/restic"
  PATH="$fakebin:$PATH" run offsite_backup::_restic_path
  [ "$output" = "$fakebin/restic" ]
}

@test "_password_file_path locates the password under the repository's own config dir" {
  HOME=/fake/home
  unset XDG_CONFIG_HOME
  run offsite_backup::_password_file_path "fake_repo"
  [ "$output" = "/fake/home/.config/machinekit/offsite_backup/fake_repo/repository_password" ]
}

@test "_credentials_file_path locates the credentials under the repository's own config dir" {
  HOME=/fake/home
  unset XDG_CONFIG_HOME
  run offsite_backup::_credentials_file_path "fake_repo"
  [ "$output" = "/fake/home/.config/machinekit/offsite_backup/fake_repo/credentials" ]
}

@test "_manifest_path gives each repository its own manifest" {
  HOME=/fake/home
  unset XDG_DATA_HOME
  run offsite_backup::_manifest_path "fake_repo"
  [ "$output" = "/fake/home/.local/share/machinekit/offsite_backup/manifest-fake_repo.tsv" ]
}

@test "_run_script_path locates the one installed run script under the default data dir" {
  HOME=/fake/home
  unset XDG_DATA_HOME
  run offsite_backup::_run_script_path
  [ "$output" = "/fake/home/.local/share/machinekit/offsite_backup/restic_run.sh" ]
}
