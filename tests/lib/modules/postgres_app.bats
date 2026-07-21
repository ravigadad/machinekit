#!/usr/bin/env bats
# Tests for lib/modules/postgres_app.sh — the Postgres.app satisfier: it checks
# (never creates) that the requested servers are running and provides the
# Postgres.app-specific capability seams. The satisfier-independent SQL/connection
# API is tested in capabilities/postgres.bats.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/postgres_app.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres_app.sh"

  mktest::stub_function logging::step
  mktest::stub_function logging::debug
}

# --- postgres_app::provides ---

@test "provides declares the postgres capability" {
  result=$(postgres_app::provides)
  [ "$result" = "postgres" ]
}

# --- postgres_app::install ---

@test "install checks the requested versions and ensures the superuser" {
  mktest::stub_function postgres_app::_assert_app_installed
  STUB_OUTPUT='the-version-array' mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres_app::_check_requested
  mktest::stub_function postgres_app::_check_default
  mktest::stub_function postgres::ensure_superuser
  postgres_app::install
  mktest::assert_stub_called postgres_app::_assert_app_installed
  mktest::assert_stub_called postgres_app::_check_requested 'the-version-array'
  mktest::assert_stub_not_called postgres_app::_check_default
  mktest::assert_stub_called postgres::ensure_superuser
}

@test "install checks the default 5432 server when no versions are configured" {
  mktest::stub_function postgres_app::_assert_app_installed
  STUB_RETURN=1 mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres_app::_check_requested
  mktest::stub_function postgres_app::_check_default
  mktest::stub_function postgres::ensure_superuser
  postgres_app::install
  mktest::assert_stub_called postgres_app::_check_default
  mktest::assert_stub_not_called postgres_app::_check_requested
  mktest::assert_stub_called postgres::ensure_superuser
}

# --- postgres_app::instance_major_version (seam) ---

@test "instance_major_version reports the major of the Postgres.app server on 5432" {
  STUB_OUTPUT="17" mktest::stub_function postgres_app::_running_major_on_port "5432"
  run postgres_app::instance_major_version
  [ "$output" = "17" ]
}

# --- postgres_app::bin_dir (seam) ---

@test "bin_dir points at the resolved instance's Postgres.app version bundle" {
  STUB_OUTPUT="17" mktest::stub_function postgres_app::instance_major_version
  run postgres_app::bin_dir
  [ "$output" = "/Applications/Postgres.app/Contents/Versions/17/bin" ]
}

@test "bin_dir fails clearly when no server resolves, instead of a garbage path" {
  STUB_RETURN=1 mktest::stub_function postgres_app::instance_major_version
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_app::bin_dir
  [ "$status" -ne 0 ]
  MATCH="no running Postgres.app server" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_app::ensure_extension_available (seam) ---

@test "ensure_extension_available is a no-op — Postgres.app bundles extensions" {
  run postgres_app::ensure_extension_available "vector"
  [ "$status" -eq 0 ]
}

# --- postgres_app::_check_requested ---

@test "_check_requested validates the shape, then asserts each requested server" {
  mktest::stub_function postgres::_assert_valid_request "the-array"
  STUB_OUTPUT=$'17\t5432\n14\t5433' mktest::stub_function postgres::_requested_version_rows "the-array"
  mktest::stub_function postgres_app::_assert_server_on "5432" "17"
  mktest::stub_function postgres_app::_assert_server_on "5433" "14"
  postgres_app::_check_requested "the-array"
  mktest::assert_stub_called postgres_app::_assert_server_on "5432" "17"
  mktest::assert_stub_called postgres_app::_assert_server_on "5433" "14"
}

@test "_check_requested fails on an invalid request before checking servers" {
  STUB_EXIT=1 mktest::stub_function postgres::_assert_valid_request "the-array"
  mktest::stub_function postgres_app::_assert_server_on
  run postgres_app::_check_requested "the-array"
  [ "$status" -ne 0 ]
  mktest::assert_stub_not_called postgres_app::_assert_server_on
}

# --- postgres_app::_check_default ---

@test "_check_default asserts a server on 5432" {
  mktest::stub_function postgres_app::_assert_server_on "5432"
  postgres_app::_check_default
  mktest::assert_stub_called postgres_app::_assert_server_on "5432"
}

# --- postgres_app::_assert_server_on ---

@test "_assert_server_on passes when the expected major is running on the port" {
  STUB_OUTPUT="17" mktest::stub_function postgres_app::_running_major_on_port "5432"
  mktest::stub_function lifecycle::fail
  postgres_app::_assert_server_on 5432 17
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_server_on passes with no expected major when any server runs on the port" {
  STUB_OUTPUT="17" mktest::stub_function postgres_app::_running_major_on_port "5432"
  mktest::stub_function lifecycle::fail
  postgres_app::_assert_server_on 5432
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_server_on fails when the running major differs from the expected" {
  STUB_OUTPUT="18" mktest::stub_function postgres_app::_running_major_on_port "5432"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_app::_assert_server_on 5432 17
  [ "$status" -ne 0 ]
  MATCH="not the requested" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_server_on fails (foreign) when the port is in use but not Postgres.app" {
  STUB_RETURN=1 mktest::stub_function postgres_app::_running_major_on_port "5432"
  mktest::stub_function postgres::_port_in_use "5432"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_app::_assert_server_on 5432
  [ "$status" -ne 0 ]
  MATCH="not by a Postgres.app server" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_server_on fails (unstarted) when no server is on the port" {
  STUB_RETURN=1 mktest::stub_function postgres_app::_running_major_on_port "5432"
  STUB_RETURN=1 mktest::stub_function postgres::_port_in_use "5432"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_app::_assert_server_on 5432
  [ "$status" -ne 0 ]
  MATCH="no Postgres.app server is running" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_app::_running_major_on_port ---

@test "_running_major_on_port returns the major whose cluster serves the port" {
  local root="$BATS_TEST_TMPDIR/pg"; mkdir -p "$root/var-14" "$root/var-17"
  STUB_OUTPUT="$root" mktest::stub_function postgres_app::_data_root
  STUB_OUTPUT="5432" mktest::stub_function postgres::_datadir_port "$root/var-14"
  STUB_OUTPUT="5433" mktest::stub_function postgres::_datadir_port "$root/var-17"
  run postgres_app::_running_major_on_port 5432
  [ "$output" = "14" ]
}

@test "_running_major_on_port is nonzero when no cluster serves the port" {
  local root="$BATS_TEST_TMPDIR/pg"; mkdir -p "$root/var-17"
  STUB_OUTPUT="$root" mktest::stub_function postgres_app::_data_root
  STUB_OUTPUT="5433" mktest::stub_function postgres::_datadir_port "$root/var-17"
  run ! postgres_app::_running_major_on_port 5432
}

@test "_running_major_on_port skips a not-running cluster rather than matching its empty port" {
  # A stopped cluster has no postmaster.pid: _datadir_port returns nonzero and
  # empty. That must not be treated as a match — least of all against an empty
  # target port, where a naive string compare ("" = "") would falsely match.
  local root="$BATS_TEST_TMPDIR/pg"; mkdir -p "$root/var-17"
  STUB_OUTPUT="$root" mktest::stub_function postgres_app::_data_root
  STUB_RETURN=1 mktest::stub_function postgres::_datadir_port "$root/var-17"
  run ! postgres_app::_running_major_on_port ""
}

# --- postgres_app::_assert_app_installed ---

@test "_assert_app_installed passes when Postgres.app is present" {
  _POSTGRES_APP_DIR="$BATS_TEST_TMPDIR/app"; mkdir -p "$_POSTGRES_APP_DIR"
  mktest::stub_function lifecycle::fail
  postgres_app::_assert_app_installed
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_app_installed fails when Postgres.app is absent" {
  _POSTGRES_APP_DIR="$BATS_TEST_TMPDIR/nope"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_app::_assert_app_installed
  [ "$status" -ne 0 ]
  MATCH="not installed" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_app::_data_root ---

@test "_data_root locates Postgres.app's data directory root" {
  run postgres_app::_data_root
  [ "$output" = "$HOME/Library/Application Support/Postgres" ]
}
