#!/usr/bin/env bats
# Tests for lib/modules/postgres_dump.sh — the install-time wiring of the
# scheduled database dump. The dump logic itself is tested in
# postgres_dump/dump.bats; the launchd/systemd load is service.sh's
# runtime-unverified seam and is stubbed here.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/postgres_dump.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres_dump.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
}

# --- requires ---

@test "requires the postgres capability" {
  run postgres_dump::requires
  [ "$output" = "postgres" ]
}

# --- preflight ---

@test "preflight validates the databases against the module defaults, then the schedule" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="9" mktest::stub_function postgres_dump::_retain_count
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  mktest::stub_function postgres_dump::_validate_databases '[{"name":"somedb"}]' "/fake/dumps" "9"
  mktest::stub_function service::validate_cron "0 3 * * *"
  postgres_dump::preflight
  mktest::assert_stub_called postgres_dump::_validate_databases '[{"name":"somedb"}]' "/fake/dumps" "9"
  mktest::assert_stub_called service::validate_cron "0 3 * * *"
}

@test "preflight is a no-op when no databases are configured" {
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_databases
  mktest::stub_function postgres_dump::_validate_databases
  mktest::stub_function service::validate_cron
  postgres_dump::preflight
  mktest::assert_stub_not_called postgres_dump::_validate_databases
  mktest::assert_stub_not_called service::validate_cron
}

@test "preflight stops when reading the databases fails" {
  STUB_EXIT=97 mktest::stub_function postgres_dump::_databases
  run postgres_dump::preflight
  [ "$status" -eq 97 ]
}

@test "preflight stops when reading the default directory fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_EXIT=97 mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="9" mktest::stub_function postgres_dump::_retain_count
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  mktest::stub_function postgres_dump::_validate_databases
  mktest::stub_function service::validate_cron
  run postgres_dump::preflight
  [ "$status" -eq 97 ]
}

@test "preflight stops when reading the default retain count fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_EXIT=97 mktest::stub_function postgres_dump::_retain_count
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  mktest::stub_function postgres_dump::_validate_databases
  mktest::stub_function service::validate_cron
  run postgres_dump::preflight
  [ "$status" -eq 97 ]
}

@test "preflight stops when reading the schedule fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="9" mktest::stub_function postgres_dump::_retain_count
  STUB_EXIT=97 mktest::stub_function postgres_dump::_schedule
  mktest::stub_function postgres_dump::_validate_databases
  mktest::stub_function service::validate_cron
  run postgres_dump::preflight
  [ "$status" -eq 97 ]
}

# --- installed_file_patterns ---

@test "installed_file_patterns names the manifest, the dump script and the password file" {
  run postgres_dump::installed_file_patterns
  [ "$status" -eq 0 ]
  [ "$output" = $'data\tmanifest.tsv\ndata\tdump.sh\nconfig\tpgpass' ]
}

# --- installed_artifacts ---

@test "installed_artifacts declares the service, its manifest, its dump script and the password file" {
  STUB_OUTPUT='[{"name":"the_db"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT="/fake/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_OUTPUT="/fake/pgpass" mktest::stub_function postgres_dump::_password_file_path
  run postgres_dump::installed_artifacts
  [ "$status" -eq 0 ]
  [ "$output" = $'service\tpostgres-dump\nfile\t/fake/manifest.tsv\nfile\t/fake/dump.sh\nfile\t/fake/pgpass' ]
}

@test "installed_artifacts declares nothing when no databases are configured" {
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_databases
  run postgres_dump::installed_artifacts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "installed_artifacts stops when reading the databases fails" {
  STUB_EXIT=97 mktest::stub_function postgres_dump::_databases
  run postgres_dump::installed_artifacts
  [ "$status" -eq 97 ]
}

# --- install ---

@test "install lays down the manifest and the dump script, provisions the dump role, then schedules the service" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres_dump::_write_manifest
  mktest::stub_function postgres_dump::_install_dump_script
  mktest::stub_function postgres_dump::_provision_role
  mktest::stub_function postgres_dump::_install_service
  postgres_dump::install
  mktest::assert_stub_called_in_order postgres_dump::_write_manifest
  mktest::assert_stub_called_in_order postgres_dump::_install_dump_script
  mktest::assert_stub_called_in_order postgres_dump::_provision_role
  mktest::assert_stub_called_in_order postgres_dump::_install_service
}

@test "install is a no-op when no databases are configured" {
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_databases
  mktest::stub_function postgres_dump::_write_manifest
  postgres_dump::install
  mktest::assert_stub_not_called postgres_dump::_write_manifest
  mktest::assert_stub_called logging::debug
}

@test "install reports and does nothing in dry-run" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  mktest::stub_function input::is_dry_run
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  mktest::stub_function postgres_dump::_write_manifest
  postgres_dump::install
  mktest::assert_stub_not_called postgres_dump::_write_manifest
  mktest::assert_stub_called logging::dry_run
}

@test "install stops when reading the databases fails" {
  STUB_EXIT=97 mktest::stub_function postgres_dump::_databases
  run postgres_dump::install
  [ "$status" -eq 97 ]
}

@test "install in dry-run stops when reading the schedule fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  mktest::stub_function input::is_dry_run
  STUB_EXIT=97 mktest::stub_function postgres_dump::_schedule
  run postgres_dump::install
  [ "$status" -eq 97 ]
}

# --- postflight_info ---

@test "postflight_info reports each database's destination and schedule" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  run postgres_dump::postflight_info
  [[ "$output" == *"somedb"* ]]
  [[ "$output" == *"/fake/dumps"* ]]
  [[ "$output" == *"0 3 * * *"* ]]
}

@test "postflight_info prefers a database's own directory over the module default" {
  STUB_OUTPUT='[{"name":"somedb","directory":"/fake/elsewhere"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  run postgres_dump::postflight_info
  [[ "$output" == *"/fake/elsewhere"* ]]
}

@test "postflight_info emits one line per configured database" {
  STUB_OUTPUT='[{"name":"somedb"},{"name":"otherdb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  run postgres_dump::postflight_info
  [ "${#lines[@]}" -eq 2 ]
}

@test "postflight_info emits nothing when no databases are configured" {
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_databases
  run postgres_dump::postflight_info
  [ -z "$output" ]
}

@test "postflight_info stops when reading the databases fails" {
  STUB_EXIT=97 mktest::stub_function postgres_dump::_databases
  run postgres_dump::postflight_info
  [ "$status" -eq 97 ]
}

@test "postflight_info stops when reading the default directory fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_EXIT=97 mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  run postgres_dump::postflight_info
  [ "$status" -eq 97 ]
}

@test "postflight_info stops when reading the schedule fails" {
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_EXIT=97 mktest::stub_function postgres_dump::_schedule
  run postgres_dump::postflight_info
  [ "$status" -eq 97 ]
}

# --- _validate_databases ---

@test "_validate_databases passes a well-formed database set" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_database_shape_error \
    '[{"name":"somedb"}]' "/fake/dumps" "7"
  postgres_dump::_validate_databases '[{"name":"somedb"}]' "/fake/dumps" "7"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_databases fails with the problem the shape check found" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  STUB_OUTPUT="some shape problem" mktest::stub_function postgres_dump::_database_shape_error
  run ! postgres_dump::_validate_databases '[{}]' "" ""
  MATCH="some shape problem" mktest::assert_stub_called lifecycle::fail
}

# --- _database_shape_error ---

@test "_database_shape_error finds nothing wrong with a well-formed set" {
  run postgres_dump::_database_shape_error '[{"name":"somedb"}]' "/fake/dumps" "7"
  [ -z "$output" ]
}

@test "_database_shape_error reports an entry with no name" {
  run postgres_dump::_database_shape_error '[{"directory":"/fake/dumps"}]' "/fake/dumps" "7"
  [[ "$output" == *"name"* ]]
}

@test "_database_shape_error reports an entry with no directory anywhere to resolve" {
  run postgres_dump::_database_shape_error '[{"name":"somedb"}]' "" "7"
  [[ "$output" == *"directory"* ]]
}

@test "_database_shape_error accepts an entry whose own directory covers a missing default" {
  run postgres_dump::_database_shape_error '[{"name":"somedb","directory":"/fake/own"}]' "" "7"
  [ -z "$output" ]
}

# Keys are unique, but an explicit name can repeat another entry's, and two
# entries for one database would dump to the same files.
@test "_database_shape_error reports a non-numeric retain_count" {
  run postgres_dump::_database_shape_error '[{"name":"somedb","retain_count":"lots"}]' "/fake/dumps" "7"
  [[ "$output" == *"retain_count"* ]]
}

@test "_database_shape_error reports a non-numeric module-level retain_count" {
  run postgres_dump::_database_shape_error '[{"name":"somedb"}]' "/fake/dumps" "lots"
  [[ "$output" == *"retain_count"* ]]
}

# --- _write_manifest ---

@test "_write_manifest writes a row per database via _manifest_row" {
  local manifest="$BATS_TEST_TMPDIR/out/manifest.tsv"
  STUB_OUTPUT="$manifest" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT='[{"name":"somedb"},{"name":"otherdb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="7" mktest::stub_function postgres_dump::_retain_count
  STUB_OUTPUT="manifest-row" mktest::stub_function postgres_dump::_manifest_row
  postgres_dump::_write_manifest
  mktest::assert_stub_called postgres_dump::_manifest_row '{"name":"somedb"}' "/fake/dumps" "7"
  mktest::assert_stub_called postgres_dump::_manifest_row '{"name":"otherdb"}' "/fake/dumps" "7"
  [ "$(grep -c 'manifest-row' "$manifest")" -eq 2 ]
}

@test "_write_manifest stops when reading the databases fails" {
  STUB_EXIT=97 mktest::stub_function postgres_dump::_databases
  run postgres_dump::_write_manifest
  [ "$status" -eq 97 ]
}

@test "_write_manifest stops when reading the default directory fails" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/out/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_EXIT=97 mktest::stub_function postgres_dump::_directory
  STUB_OUTPUT="7" mktest::stub_function postgres_dump::_retain_count
  mktest::stub_function postgres_dump::_manifest_row
  run postgres_dump::_write_manifest
  [ "$status" -eq 97 ]
}

@test "_write_manifest stops when reading the default retain count fails" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/out/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT='[{"name":"somedb"}]' mktest::stub_function postgres_dump::_databases
  STUB_OUTPUT="/fake/dumps" mktest::stub_function postgres_dump::_directory
  STUB_EXIT=97 mktest::stub_function postgres_dump::_retain_count
  mktest::stub_function postgres_dump::_manifest_row
  run postgres_dump::_write_manifest
  [ "$status" -eq 97 ]
}

# --- _manifest_row ---

@test "_manifest_row emits the name with the module's directory and retain_count" {
  run postgres_dump::_manifest_row '{"name":"somedb"}' "/fake/dumps" "7"
  [ "$output" = "$(printf 'somedb\t/fake/dumps\t7')" ]
}

@test "_manifest_row prefers the database's own directory and retain_count" {
  run postgres_dump::_manifest_row \
    '{"name":"somedb","directory":"/fake/own","retain_count":2}' "/fake/dumps" "7"
  [ "$output" = "$(printf 'somedb\t/fake/own\t2')" ]
}

@test "_manifest_row expands a leading ~ in the directory" {
  run postgres_dump::_manifest_row '{"name":"somedb","directory":"~/dumps"}' "/fake/dumps" "7"
  [ "$output" = "$(printf 'somedb\t%s/dumps\t7' "$HOME")" ]
}

@test "_manifest_row expands a leading ~ in the module default directory" {
  # A literal ~, as a blueprint writes it, for the code under test to expand.
  # shellcheck disable=SC2088
  run postgres_dump::_manifest_row '{"name":"somedb"}' "~/dumps" "7"
  [ "$output" = "$(printf 'somedb\t%s/dumps\t7' "$HOME")" ]
}

# --- _install_dump_script ---

@test "_install_dump_script installs the real script as executable" {
  local dest="$BATS_TEST_TMPDIR/install/dump.sh"
  STUB_OUTPUT="$dest" mktest::stub_function postgres_dump::_dump_script_path
  postgres_dump::_install_dump_script
  [ -x "$dest" ]
  grep -q "pg_restore --list" "$dest"
}

# --- _install_service ---

@test "_install_service schedules the dump script on the calendar with the pinned env" {
  STUB_OUTPUT="/s/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function postgres_dump::_notify
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  STUB_OUTPUT="/b/pg_dump" mktest::stub_function postgres::pg_dump_path
  STUB_OUTPUT="/b/pg_restore" mktest::stub_function postgres::pg_restore_path
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="/c/pgpass" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function service::install_calendar
  postgres_dump::_install_service
  mktest::assert_stub_called service::install_calendar \
    "postgres-dump" "/s/dump.sh" "0 3 * * *" \
    "MK_POSTGRES_DUMP_MANIFEST=/m/manifest.tsv" \
    "MK_POSTGRES_DUMP_NOTIFY=/n/notify" \
    "MK_POSTGRES_DUMP_PG_DUMP=/b/pg_dump" \
    "MK_POSTGRES_DUMP_PG_RESTORE=/b/pg_restore" \
    "MK_POSTGRES_DUMP_USER=$_POSTGRES_DUMP_ROLE" \
    "MK_POSTGRES_DUMP_PORT=7777" \
    "PGPASSFILE=/c/pgpass"
}

# --- _provision_role ---

@test "_provision_role sets the role's password from the password file, grants read access, then requires password login" {
  mktest::stub_function postgres_dump::_ensure_password_file
  STUB_OUTPUT="fake-password" mktest::stub_function postgres_dump::_password_from_file
  mktest::stub_function postgres::ensure_role
  mktest::stub_function postgres::grant_read_all_data
  mktest::stub_function postgres::require_password_login
  postgres_dump::_provision_role
  mktest::assert_stub_called_in_order postgres_dump::_ensure_password_file
  mktest::assert_stub_called_in_order postgres::ensure_role "$_POSTGRES_DUMP_ROLE" "fake-password"
  mktest::assert_stub_called_in_order postgres::grant_read_all_data "$_POSTGRES_DUMP_ROLE"
  mktest::assert_stub_called_in_order postgres::require_password_login "$_POSTGRES_DUMP_ROLE"
}

@test "_provision_role stops when the password can't be read" {
  mktest::stub_function postgres_dump::_ensure_password_file
  STUB_EXIT=97 mktest::stub_function postgres_dump::_password_from_file
  mktest::stub_function postgres::ensure_role
  mktest::stub_function postgres::grant_read_all_data
  mktest::stub_function postgres::require_password_login
  run postgres_dump::_provision_role
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called postgres::ensure_role
}

# --- _ensure_password_file ---

@test "_ensure_password_file writes a new password file in a private directory" {
  local path="$BATS_TEST_TMPDIR/config/postgres_dump/pgpass"
  STUB_OUTPUT="$path" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function secrets::install_secret_file "$path" postgres_dump::_pgpass_line
  postgres_dump::_ensure_password_file
  mktest::assert_stub_called secrets::install_secret_file "$path" postgres_dump::_pgpass_line
  [ "$(stat -f %Lp "$(dirname "$path")" 2>/dev/null || stat -c %a "$(dirname "$path")")" = "700" ]
}

@test "_ensure_password_file keeps an existing password file" {
  local path="$BATS_TEST_TMPDIR/pgpass"
  printf 'existing\n' > "$path"
  STUB_OUTPUT="$path" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function secrets::install_secret_file
  postgres_dump::_ensure_password_file
  mktest::assert_stub_not_called secrets::install_secret_file
}

@test "_ensure_password_file fails when the file can't be written" {
  local path="$BATS_TEST_TMPDIR/config/pgpass"
  STUB_OUTPUT="$path" mktest::stub_function postgres_dump::_password_file_path
  STUB_RETURN=1 mktest::stub_function secrets::install_secret_file
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_dump::_ensure_password_file
  [ "$status" -ne 0 ]
  MATCH="$path" mktest::assert_stub_called lifecycle::fail
}

# --- _pgpass_line ---

@test "_pgpass_line is a libpq password-file line for the dump role on the capability's port" {
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="fake-password" mktest::stub_function postgres_dump::_generate_password
  run postgres_dump::_pgpass_line
  [ "$output" = "localhost:7777:*:$_POSTGRES_DUMP_ROLE:fake-password" ]
}

@test "_pgpass_line produces nothing when no password could be generated" {
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="" mktest::stub_function postgres_dump::_generate_password
  run postgres_dump::_pgpass_line
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- _password_from_file ---

@test "_password_from_file reads the password field of the password-file line" {
  local path="$BATS_TEST_TMPDIR/pgpass"
  printf 'localhost:7777:*:fake_role:fake-password\n' > "$path"
  STUB_OUTPUT="$path" mktest::stub_function postgres_dump::_password_file_path
  run postgres_dump::_password_from_file
  [ "$output" = "fake-password" ]
}

@test "_password_from_file fails when the file holds no password" {
  local path="$BATS_TEST_TMPDIR/pgpass"
  printf 'localhost:7777:*:fake_role:\n' > "$path"
  STUB_OUTPUT="$path" mktest::stub_function postgres_dump::_password_file_path
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_dump::_password_from_file
  [ "$status" -ne 0 ]
  MATCH="$path" mktest::assert_stub_called lifecycle::fail
}

@test "_install_service stops when reading the schedule fails" {
  STUB_OUTPUT="/s/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_EXIT=97 mktest::stub_function postgres_dump::_schedule
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function postgres_dump::_notify
  STUB_OUTPUT="/b/pg_dump" mktest::stub_function postgres::pg_dump_path
  STUB_OUTPUT="/b/pg_restore" mktest::stub_function postgres::pg_restore_path
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="/c/pgpass" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function service::install_calendar
  run postgres_dump::_install_service
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called service::install_calendar
}

@test "_install_service stops when reading the notify command fails" {
  STUB_OUTPUT="/s/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_EXIT=97 mktest::stub_function postgres_dump::_notify
  STUB_OUTPUT="/b/pg_dump" mktest::stub_function postgres::pg_dump_path
  STUB_OUTPUT="/b/pg_restore" mktest::stub_function postgres::pg_restore_path
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="/c/pgpass" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function service::install_calendar
  run postgres_dump::_install_service
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called service::install_calendar
}

@test "_install_service stops when resolving pg_dump fails" {
  STUB_OUTPUT="/s/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function postgres_dump::_notify
  STUB_EXIT=97 mktest::stub_function postgres::pg_dump_path
  STUB_OUTPUT="/b/pg_restore" mktest::stub_function postgres::pg_restore_path
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="/c/pgpass" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function service::install_calendar
  run postgres_dump::_install_service
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called service::install_calendar
}

@test "_install_service stops when resolving pg_restore fails" {
  STUB_OUTPUT="/s/dump.sh" mktest::stub_function postgres_dump::_dump_script_path
  STUB_OUTPUT="0 3 * * *" mktest::stub_function postgres_dump::_schedule
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function postgres_dump::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function postgres_dump::_notify
  STUB_OUTPUT="/b/pg_dump" mktest::stub_function postgres::pg_dump_path
  STUB_EXIT=97 mktest::stub_function postgres::pg_restore_path
  STUB_OUTPUT="7777" mktest::stub_function postgres::port
  STUB_OUTPUT="/c/pgpass" mktest::stub_function postgres_dump::_password_file_path
  mktest::stub_function service::install_calendar
  run postgres_dump::_install_service
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called service::install_calendar
}

# --- config accessors + paths ---

@test "_databases returns the configured databases, each key filling the database name" {
  STUB_OUTPUT="the-databases" mktest::stub_function config::entries "module.postgres_dump.databases" "name"
  run postgres_dump::_databases
  [ "$output" = "the-databases" ]
}

@test "_schedule defaults to a nightly run" {
  STUB_OUTPUT="30 2 * * *" mktest::stub_function config::get \
    "module.postgres_dump.schedule" "--default" "0 3 * * *"
  run postgres_dump::_schedule
  [ "$output" = "30 2 * * *" ]
}

@test "_directory defaults to empty, so a missing one is a preflight failure not a guess" {
  STUB_OUTPUT="/fake/dumps" mktest::stub_function config::get \
    "module.postgres_dump.directory" "--default" ""
  run postgres_dump::_directory
  [ "$output" = "/fake/dumps" ]
}

@test "_retain_count defaults to 7" {
  STUB_OUTPUT="14" mktest::stub_function config::get \
    "module.postgres_dump.retain_count" "--default" "7"
  run postgres_dump::_retain_count
  [ "$output" = "14" ]
}

@test "_notify defaults to empty" {
  STUB_OUTPUT="" mktest::stub_function config::get "module.postgres_dump.notify" "--default" ""
  run postgres_dump::_notify
  [ -z "$output" ]
}

@test "_manifest_path places the manifest in the module's own data dir" {
  STUB_OUTPUT="/fake/data/postgres_dump" mktest::stub_function artifacts::module_data_dir postgres_dump
  run postgres_dump::_manifest_path
  [ "$output" = "/fake/data/postgres_dump/manifest.tsv" ]
}

@test "_password_file_path places the password file in the module's own config dir" {
  STUB_OUTPUT="/fake/config/postgres_dump" mktest::stub_function artifacts::module_config_dir postgres_dump
  run postgres_dump::_password_file_path
  [ "$output" = "/fake/config/postgres_dump/pgpass" ]
}

@test "_dump_script_path places the installed dump script in the module's own data dir" {
  STUB_OUTPUT="/fake/data/postgres_dump" mktest::stub_function artifacts::module_data_dir postgres_dump
  run postgres_dump::_dump_script_path
  [ "$output" = "/fake/data/postgres_dump/dump.sh" ]
}

