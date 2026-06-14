#!/usr/bin/env bats
# Tests for lib/modules/postgres/introspect.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/postgres/introspect.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres/introspect.sh"
}

# --- postgres::introspect::formula ---

@test "formula builds the versioned formula name" {
  run postgres::introspect::formula 14
  [ "$output" = "postgresql@14" ]
}

# A missing version is a usage error (shape check, no I/O), distinct from a
# bogus-but-present version, which is left to fail at the brew boundary.
@test "formula fails when called without a version" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::introspect::formula
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  mktest::assert_stub_called lifecycle::fail
}

# --- postgres::introspect::installed_versions ---

@test "installed_versions lists installed postgres majors, stripping the formula prefix" {
  STUB_OUTPUT=$'git\npostgresql@14\njq\npostgresql@17' \
    mktest::stub_function brew::_installed "formula"
  run postgres::introspect::installed_versions
  [ "$output" = $'14\n17' ]
}

@test "installed_versions is empty when no postgres formula is installed" {
  STUB_OUTPUT=$'git\njq' mktest::stub_function brew::_installed "formula"
  run postgres::introspect::installed_versions
  [ -z "$output" ]
}

# --- postgres::introspect::is_installed ---

@test "is_installed delegates to brew with the versioned formula name" {
  STUB_OUTPUT="fake-formula" mktest::stub_function postgres::introspect::formula "14"
  mktest::stub_function brew::_is_installed "formula" "fake-formula"
  postgres::introspect::is_installed 14
  mktest::assert_stub_called brew::_is_installed "formula" "fake-formula"
}

@test "is_installed is false when brew reports the formula absent" {
  STUB_OUTPUT="fake-formula" mktest::stub_function postgres::introspect::formula "14"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "fake-formula"
  run ! postgres::introspect::is_installed 14
}

# --- postgres::introspect::latest_available_version ---

@test "latest_available_version resolves the postgresql alias to its major via brew metadata" {
  STUB_OUTPUT='{"formulae":[{"name":"postgresql@18"}]}' \
    mktest::stub_function brew "info" "--json=v2" "postgresql"
  run postgres::introspect::latest_available_version
  [ "$output" = "18" ]
}

# --- postgres::introspect::data_dir ---

@test "data_dir locates the cluster under the brew prefix var directory" {
  STUB_OUTPUT="/fake/brew" mktest::stub_function brew "--prefix"
  STUB_OUTPUT="fake-formula" mktest::stub_function postgres::introspect::formula "14"
  run postgres::introspect::data_dir 14
  [ "$output" = "/fake/brew/var/fake-formula" ]
}

# --- postgres::introspect::bin_dir ---

@test "bin_dir resolves the keg-only bin directory for the version" {
  STUB_OUTPUT="fake-formula" mktest::stub_function postgres::introspect::formula "14"
  STUB_OUTPUT="/fake/keg" mktest::stub_function brew "--prefix" "fake-formula"
  run postgres::introspect::bin_dir 14
  [ "$output" = "/fake/keg/bin" ]
}

# --- postgres::introspect::pg_ctl_path ---

@test "pg_ctl_path points at pg_ctl inside the version's bin directory" {
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::introspect::bin_dir "14"
  run postgres::introspect::pg_ctl_path 14
  [ "$output" = "/fake/bin/pg_ctl" ]
}

# --- postgres::introspect::is_initialized ---

@test "is_initialized is true when the cluster has a PG_VERSION stamp" {
  local datadir="$BATS_TEST_TMPDIR/datadir"; mkdir -p "$datadir"; : > "$datadir/PG_VERSION"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  postgres::introspect::is_initialized 14
}

@test "is_initialized is false when the data directory lacks PG_VERSION" {
  local datadir="$BATS_TEST_TMPDIR/datadir"; mkdir -p "$datadir"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  run ! postgres::introspect::is_initialized 14
}

# --- postgres::introspect::configured_port ---

@test "configured_port reads an explicit uncommented port from postgresql.conf" {
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  printf 'port = 5433\n' > "$datadir/postgresql.conf"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  run postgres::introspect::configured_port 14
  [ "$output" = "5433" ]
}

@test "configured_port treats a commented port line as the 5432 default" {
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  printf '#port = 5433\n' > "$datadir/postgresql.conf"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  run postgres::introspect::configured_port 14
  [ "$output" = "5432" ]
}

@test "configured_port defaults to 5432 when no port line is present" {
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  printf 'max_connections = 100\n' > "$datadir/postgresql.conf"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  run postgres::introspect::configured_port 14
  [ "$output" = "5432" ]
}

@test "configured_port defaults to 5432 when the config file is absent" {
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  run postgres::introspect::configured_port 14
  [ "$output" = "5432" ]
}

# --- postgres::introspect::is_running ---

@test "is_running is true when pg_ctl reports the cluster up" {
  STUB_OUTPUT="fake_pg_ctl" mktest::stub_function postgres::introspect::pg_ctl_path "14"
  STUB_OUTPUT="/fake/datadir" mktest::stub_function postgres::introspect::data_dir "14"
  mktest::stub_function fake_pg_ctl "status" "-D" "/fake/datadir"
  postgres::introspect::is_running 14
  mktest::assert_stub_called fake_pg_ctl "status" "-D" "/fake/datadir"
}

@test "is_running is false when pg_ctl reports the cluster down" {
  STUB_OUTPUT="fake_pg_ctl" mktest::stub_function postgres::introspect::pg_ctl_path "14"
  STUB_OUTPUT="/fake/datadir" mktest::stub_function postgres::introspect::data_dir "14"
  STUB_RETURN=3 mktest::stub_function fake_pg_ctl "status" "-D" "/fake/datadir"
  run ! postgres::introspect::is_running 14
  mktest::assert_stub_called fake_pg_ctl "status" "-D" "/fake/datadir"
}

# --- postgres::introspect::instance_version ---
# "The instance" = the initialized cluster on port 5432. The one dynamic fact
# the module computes; everything else follows from the major it returns.

@test "instance_version picks the initialized major configured on port 5432" {
  STUB_OUTPUT=$'14\n17' mktest::stub_function postgres::introspect::installed_versions
  mktest::stub_function postgres::introspect::is_initialized "14"
  mktest::stub_function postgres::introspect::is_initialized "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres::introspect::configured_port "14"
  STUB_OUTPUT="5432" mktest::stub_function postgres::introspect::configured_port "17"
  run postgres::introspect::instance_version
  [ "$status" -eq 0 ]
  [ "$output" = "17" ]
}

# The guard that matters: configured_port defaults to 5432 for an uninitialized
# install, so without the is_initialized check this would false-match 18.
@test "instance_version skips an installed-but-uninitialized major despite the 5432 port default" {
  STUB_OUTPUT="18" mktest::stub_function postgres::introspect::installed_versions
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_initialized "18"
  STUB_OUTPUT="5432" mktest::stub_function postgres::introspect::configured_port
  run postgres::introspect::instance_version
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  mktest::assert_stub_not_called postgres::introspect::configured_port
}

@test "instance_version fails when no installed major is on 5432" {
  STUB_OUTPUT="14" mktest::stub_function postgres::introspect::installed_versions
  mktest::stub_function postgres::introspect::is_initialized "14"
  STUB_OUTPUT="5433" mktest::stub_function postgres::introspect::configured_port "14"
  run postgres::introspect::instance_version
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "instance_version fails when no postgres is installed" {
  STUB_OUTPUT="" mktest::stub_function postgres::introspect::installed_versions
  run postgres::introspect::instance_version
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
