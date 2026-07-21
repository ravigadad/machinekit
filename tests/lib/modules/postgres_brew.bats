#!/usr/bin/env bats
# Tests for lib/modules/postgres_brew.sh — the brew satisfier's hooks, install
# orchestration, and capability seams. The satisfier-independent consumer API is
# tested in capabilities/postgres.bats; read-only brew introspection in
# postgres_brew/introspect.bats; container access in postgres_brew/access.bats.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/postgres_brew.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres_brew.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::success
}

# --- postgres_brew::provides ---

@test "provides declares the postgres capability" {
  result=$(postgres_brew::provides)
  [ "$result" = "postgres" ]
}

# --- postgres_brew::install (dispatch + superuser) ---

@test "install routes to the requested-versions path and ensures the superuser" {
  STUB_OUTPUT='the-version-array' mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres_brew::_install_requested
  mktest::stub_function postgres_brew::_install_default
  mktest::stub_function postgres::ensure_superuser
  postgres_brew::install
  mktest::assert_stub_called postgres_brew::_install_requested 'the-version-array'
  mktest::assert_stub_not_called postgres_brew::_install_default
  mktest::assert_stub_called postgres::ensure_superuser
}

@test "install routes to the default path when no versions are configured" {
  STUB_RETURN=1 mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres_brew::_install_requested
  mktest::stub_function postgres_brew::_install_default
  mktest::stub_function postgres::ensure_superuser
  postgres_brew::install
  mktest::assert_stub_called postgres_brew::_install_default
  mktest::assert_stub_not_called postgres_brew::_install_requested
  mktest::assert_stub_called postgres::ensure_superuser
}

# --- postgres_brew::post_apply ---

@test "post_apply delegates to access configuration" {
  mktest::stub_function postgres_brew::access::configure
  postgres_brew::post_apply
  mktest::assert_stub_called postgres_brew::access::configure
}

# --- postgres_brew::instance_major_version (seam) ---

@test "instance_major_version reports the brew instance major on 5432" {
  STUB_OUTPUT="18" mktest::stub_function postgres_brew::introspect::instance_version
  run postgres_brew::instance_major_version
  [ "$output" = "18" ]
}

# --- postgres_brew::bin_dir (seam) ---

@test "bin_dir resolves the keg bin directory for the resolved instance" {
  STUB_OUTPUT="17" mktest::stub_function postgres_brew::introspect::instance_version
  STUB_OUTPUT="/fake/keg/bin" mktest::stub_function postgres_brew::introspect::bin_dir "17"
  run postgres_brew::bin_dir
  [ "$output" = "/fake/keg/bin" ]
}

# --- postgres_brew::ensure_extension_available (seam) ---

@test "ensure_extension_available installs the extension's brew formula" {
  STUB_OUTPUT="pgvector" mktest::stub_function postgres_brew::_extension_formula "vector"
  mktest::stub_function brew::install_formula "pgvector"
  postgres_brew::ensure_extension_available "vector"
  mktest::assert_stub_called brew::install_formula "pgvector"
}

# --- postgres_brew::_extension_formula ---

@test "_extension_formula maps the vector extension to the pgvector formula" {
  run postgres_brew::_extension_formula "vector"
  [ "$output" = "pgvector" ]
}

@test "_extension_formula fails for an extension with no known formula" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_brew::_extension_formula "bogus"
  [ "$status" -ne 0 ]
  MATCH="no known brew formula" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_brew::_install_requested ---

@test "_install_requested validates the request, then ensures each version" {
  mktest::stub_function postgres::_assert_valid_request "the-version-array"
  mktest::stub_function postgres_brew::_assert_compatible_with_installed
  mktest::stub_function postgres_brew::_ensure_requested
  postgres_brew::_install_requested "the-version-array"
  mktest::assert_stub_called_in_order postgres::_assert_valid_request "the-version-array"
  mktest::assert_stub_called_in_order postgres_brew::_assert_compatible_with_installed "the-version-array"
  mktest::assert_stub_called_in_order postgres_brew::_ensure_requested "the-version-array"
}

@test "_install_requested fails on an invalid request before ensuring anything" {
  STUB_EXIT=1 mktest::stub_function postgres::_assert_valid_request "the-version-array"
  mktest::stub_function postgres_brew::_assert_compatible_with_installed
  mktest::stub_function postgres_brew::_ensure_requested
  run postgres_brew::_install_requested "the-version-array"
  [ "$status" -ne 0 ]
  mktest::assert_stub_not_called postgres_brew::_assert_compatible_with_installed
  mktest::assert_stub_not_called postgres_brew::_ensure_requested
}

# --- postgres_brew::_install_default ---

@test "_install_default uses the existing 5432 instance instead of installing" {
  STUB_OUTPUT="17" mktest::stub_function postgres_brew::introspect::instance_version
  mktest::stub_function postgres_brew::_ensure_running "17"
  mktest::stub_function postgres_brew::_install_on_port
  postgres_brew::_install_default
  mktest::assert_stub_called postgres_brew::_ensure_running "17"
  mktest::assert_stub_not_called postgres_brew::_install_on_port
}

@test "_install_default installs the latest major on 5432 when nothing is there" {
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres_brew::introspect::latest_available_version
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::is_installed "18"
  mktest::stub_function postgres_brew::_install_on_port "18" "5432"
  postgres_brew::_install_default
  mktest::assert_stub_called postgres_brew::_install_on_port "18" "5432"
}

@test "_install_default fails when the latest major already has a cluster on another port" {
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres_brew::introspect::latest_available_version
  mktest::stub_function postgres_brew::introspect::is_installed "18"
  mktest::stub_function postgres_brew::introspect::is_initialized "18"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function postgres_brew::_install_on_port
  run postgres_brew::_install_default
  [ "$status" -ne 0 ]
  MATCH="non-5432 port" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called postgres_brew::_install_on_port
}

@test "_install_default fails when the latest major is installed but never initialized" {
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres_brew::introspect::latest_available_version
  mktest::stub_function postgres_brew::introspect::is_installed "18"
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::is_initialized "18"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function postgres_brew::_install_on_port
  run postgres_brew::_install_default
  [ "$status" -ne 0 ]
  MATCH="never initialized" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called postgres_brew::_install_on_port
}

# --- postgres_brew::_assert_compatible_with_installed ---

@test "_assert_compatible_with_installed passes when installs match the request" {
  local requested='[{"version":"17","port":"5432"},{"version":"14","port":"5433"}]'
  STUB_OUTPUT=$'17\n14' mktest::stub_function postgres_brew::introspect::installed_versions
  mktest::stub_function postgres_brew::introspect::is_initialized "17"
  mktest::stub_function postgres_brew::introspect::is_initialized "14"
  STUB_OUTPUT="5432" mktest::stub_function postgres_brew::introspect::configured_port "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres_brew::introspect::configured_port "14"
  mktest::stub_function lifecycle::fail
  postgres_brew::_assert_compatible_with_installed "$requested"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version is absent from the request" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT=$'17\n14' mktest::stub_function postgres_brew::introspect::installed_versions
  mktest::stub_function postgres_brew::introspect::is_initialized
  STUB_OUTPUT="5432" mktest::stub_function postgres_brew::introspect::configured_port
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_brew::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="not in the requested" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version was never initialized" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT="17" mktest::stub_function postgres_brew::introspect::installed_versions
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::is_initialized "17"
  mktest::stub_function postgres_brew::introspect::configured_port "17"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_brew::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="never initialized" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version's port differs from the request" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT="17" mktest::stub_function postgres_brew::introspect::installed_versions
  mktest::stub_function postgres_brew::introspect::is_initialized "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres_brew::introspect::configured_port "17"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_brew::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="will not change.*port" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_brew::_ensure_requested ---

@test "_ensure_requested starts installed versions and installs missing ones on their ports" {
  STUB_OUTPUT=$'17\t5432\n14\t5433' mktest::stub_function postgres::_requested_version_rows "the-array"
  mktest::stub_function postgres_brew::introspect::is_installed "17"
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::is_installed "14"
  mktest::stub_function postgres_brew::_ensure_running "17"
  mktest::stub_function postgres_brew::_install_on_port "14" "5433"
  postgres_brew::_ensure_requested "the-array"
  mktest::assert_stub_called postgres_brew::_ensure_running "17"
  mktest::assert_stub_called postgres_brew::_install_on_port "14" "5433"
}

# --- postgres_brew::_install_on_port ---

@test "_install_on_port installs and starts the 5432 instance without touching its port" {
  mktest::stub_function postgres_brew::_assert_port_not_foreign "5432"
  STUB_OUTPUT="postgresql@18" mktest::stub_function postgres_brew::introspect::formula "18"
  mktest::stub_function brew::install_formula "postgresql@18"
  mktest::stub_function postgres_brew::_set_port
  mktest::stub_function postgres_brew::_start "18"
  postgres_brew::_install_on_port 18 5432
  mktest::assert_stub_called_in_order postgres_brew::_assert_port_not_foreign "5432"
  mktest::assert_stub_called_in_order brew::install_formula "postgresql@18"
  mktest::assert_stub_called_in_order postgres_brew::_start "18"
  mktest::assert_stub_not_called postgres_brew::_set_port
}

@test "_install_on_port installs an alt-port version, sets its port, then starts it" {
  mktest::stub_function postgres_brew::_assert_port_not_foreign "5433"
  STUB_OUTPUT="postgresql@14" mktest::stub_function postgres_brew::introspect::formula "14"
  mktest::stub_function brew::install_formula "postgresql@14"
  mktest::stub_function postgres_brew::_set_port "14" "5433"
  mktest::stub_function postgres_brew::_start "14"
  postgres_brew::_install_on_port 14 5433
  mktest::assert_stub_called_in_order postgres_brew::_assert_port_not_foreign "5433"
  mktest::assert_stub_called_in_order brew::install_formula "postgresql@14"
  mktest::assert_stub_called_in_order postgres_brew::_set_port "14" "5433"
  mktest::assert_stub_called_in_order postgres_brew::_start "14"
}

# --- postgres_brew::_assert_port_not_foreign ---

@test "_assert_port_not_foreign allows a free port" {
  STUB_RETURN=1 mktest::stub_function postgres::_port_in_use "5432"
  mktest::stub_function lifecycle::fail
  postgres_brew::_assert_port_not_foreign 5432
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_port_not_foreign allows a port already served by our own brew cluster" {
  mktest::stub_function postgres::_port_in_use "5432"
  mktest::stub_function postgres_brew::_port_is_my_cluster "5432"
  mktest::stub_function lifecycle::fail
  postgres_brew::_assert_port_not_foreign 5432
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_port_not_foreign fails when a foreign postgres holds the port" {
  mktest::stub_function postgres::_port_in_use "5432"
  STUB_RETURN=1 mktest::stub_function postgres_brew::_port_is_my_cluster "5432"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres_brew::_assert_port_not_foreign 5432
  [ "$status" -ne 0 ]
  MATCH="non-brew postgres" mktest::assert_stub_called lifecycle::fail
}

# --- postgres_brew::_port_is_my_cluster ---

@test "_port_is_my_cluster is true when an installed cluster's postmaster.pid reports the port" {
  STUB_OUTPUT=$'17\n14' mktest::stub_function postgres_brew::introspect::installed_versions
  STUB_OUTPUT="/data/17" mktest::stub_function postgres_brew::introspect::data_dir "17"
  STUB_OUTPUT="/data/14" mktest::stub_function postgres_brew::introspect::data_dir "14"
  STUB_OUTPUT="5433" mktest::stub_function postgres::_datadir_port "/data/17"
  STUB_OUTPUT="5432" mktest::stub_function postgres::_datadir_port "/data/14"
  postgres_brew::_port_is_my_cluster 5432
}

@test "_port_is_my_cluster is false when no installed cluster serves the port" {
  STUB_OUTPUT="17" mktest::stub_function postgres_brew::introspect::installed_versions
  STUB_OUTPUT="/data/17" mktest::stub_function postgres_brew::introspect::data_dir "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres::_datadir_port "/data/17"
  run ! postgres_brew::_port_is_my_cluster 5432
}

# --- postgres_brew::_set_port ---

@test "_set_port sets the port in postgresql.conf, preserving other lines and staying idempotent" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  printf '#port = 5432\nmax_connections = 100\n' > "$datadir/postgresql.conf"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres_brew::introspect::data_dir "14"
  postgres_brew::_set_port 14 5433
  postgres_brew::_set_port 14 5433
  run grep -c '^port = 5433$' "$datadir/postgresql.conf"
  [ "$output" = "1" ]
  run grep -c '^max_connections = 100$' "$datadir/postgresql.conf"
  [ "$output" = "1" ]
}

@test "_set_port in dry-run reports without reading or writing the config" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function logging::dry_run
  mktest::stub_function postgres_brew::introspect::data_dir
  postgres_brew::_set_port 14 5433
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called postgres_brew::introspect::data_dir
}

# --- postgres_brew::_ensure_running ---

@test "_ensure_running leaves a running instance alone" {
  mktest::stub_function postgres_brew::introspect::is_running "17"
  mktest::stub_function postgres_brew::_start
  postgres_brew::_ensure_running 17
  mktest::assert_stub_not_called postgres_brew::_start
}

@test "_ensure_running starts a stopped instance" {
  STUB_RETURN=1 mktest::stub_function postgres_brew::introspect::is_running "17"
  mktest::stub_function postgres_brew::_start "17"
  postgres_brew::_ensure_running 17
  mktest::assert_stub_called postgres_brew::_start "17"
}

# --- postgres_brew::_start ---

@test "_start starts the resolved formula's service" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="postgresql@17" mktest::stub_function postgres_brew::introspect::formula "17"
  mktest::stub_function brew::start_service "postgresql@17"
  postgres_brew::_start 17
  mktest::assert_stub_called brew::start_service "postgresql@17"
}

@test "_start in dry-run reports instead of starting the daemon" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function brew::start_service
  mktest::stub_function logging::dry_run
  postgres_brew::_start 17
  mktest::assert_stub_not_called brew::start_service
  mktest::assert_stub_called logging::dry_run
}

# --- postgres_brew::_restart ---

@test "_restart restarts the resolved formula's service" {
  STUB_OUTPUT="postgresql@17" mktest::stub_function postgres_brew::introspect::formula "17"
  mktest::stub_function brew::restart_service "postgresql@17"
  postgres_brew::_restart 17
  mktest::assert_stub_called brew::restart_service "postgresql@17"
}
