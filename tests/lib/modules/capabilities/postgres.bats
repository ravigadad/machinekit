#!/usr/bin/env bats
# Tests for lib/modules/capabilities/postgres.sh — the satisfier-independent
# consumer API (SQL provisioning, connection strings) and the seam dispatch to the
# active satisfier. Brew-specific behavior is tested in postgres_brew.bats.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/capabilities/postgres.sh
  source "$MACHINEKIT_DIR/lib/modules/capabilities/postgres.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::debug
  mktest::stub_function logging::success
}

# --- postgres::is_capability ---

@test "is_capability returns 0" {
  postgres::is_capability
}

# --- postgres::default_satisfier ---

@test "default_satisfier is postgres_brew on every OS" {
  result=$(postgres::default_satisfier)
  [ "$result" = "postgres_brew" ]
}

# --- postgres::requires ---

@test "requires pulls in the default satisfier" {
  STUB_OUTPUT="some-satisfier" mktest::stub_function postgres::default_satisfier
  result=$(postgres::requires)
  [ "$result" = "some-satisfier" ]
}

# --- postgres::install ---

@test "install is a no-op (the satisfier does the work)" {
  run postgres::install
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- postgres::version ---

@test "version dispatches the instance_major_version seam" {
  STUB_OUTPUT="18" mktest::stub_function postgres::_dispatch "instance_major_version"
  run postgres::version
  [ "$output" = "18" ]
}

# --- postgres::connection_string ---

@test "connection_string builds a host-local URL on localhost:5432" {
  run postgres::connection_string "mydb" "myuser" "host-local"
  [ "$output" = "postgresql://myuser@localhost:5432/mydb" ]
}

@test "connection_string builds a container URL via the container host alias" {
  STUB_OUTPUT="host.docker.internal" mktest::stub_function container_manager::host_alias
  run postgres::connection_string "mydb" "myuser" "container"
  [ "$output" = "postgresql://myuser@host.docker.internal:5432/mydb" ]
}

@test "connection_string fails on an unknown flavor" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::connection_string "mydb" "myuser" "bogus"
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

# --- postgres::ensure_database ---

@test "ensure_database in dry-run reports without touching postgres" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_db_exists
  mktest::stub_function postgres::_psql_exec
  mktest::stub_function logging::dry_run
  postgres::ensure_database "somedb"
  mktest::assert_stub_not_called postgres::_db_exists
  mktest::assert_stub_not_called postgres::_psql_exec
  mktest::assert_stub_called logging::dry_run
}

@test "ensure_database is a no-op when the database already exists" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_db_exists "somedb"
  mktest::stub_function postgres::_psql_exec
  postgres::ensure_database "somedb"
  mktest::assert_stub_not_called postgres::_psql_exec
}

@test "ensure_database creates the database when missing" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function postgres::_db_exists "somedb"
  mktest::stub_function postgres::_psql_exec "postgres" "-c" "CREATE DATABASE \"somedb\""
  postgres::ensure_database "somedb"
  mktest::assert_stub_called postgres::_psql_exec "postgres" "-c" "CREATE DATABASE \"somedb\""
}

@test "ensure_database creates the database, then hands ownership to the owner" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function postgres::_db_exists "somedb"
  mktest::stub_function postgres::_psql_exec "postgres" "-c" "CREATE DATABASE \"somedb\""
  mktest::stub_function postgres::_psql_exec \
    "postgres" "-c" "ALTER DATABASE \"somedb\" OWNER TO \"someowner\""
  postgres::ensure_database "somedb" "someowner"
  mktest::assert_stub_called_in_order postgres::_psql_exec "postgres" "-c" "CREATE DATABASE \"somedb\""
  mktest::assert_stub_called_in_order postgres::_psql_exec \
    "postgres" "-c" "ALTER DATABASE \"somedb\" OWNER TO \"someowner\""
}

@test "ensure_database re-asserts ownership on an existing db without recreating it" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_db_exists "somedb"
  mktest::stub_function postgres::_psql_exec \
    "postgres" "-c" "ALTER DATABASE \"somedb\" OWNER TO \"someowner\""
  postgres::ensure_database "somedb" "someowner"
  mktest::assert_stub_called postgres::_psql_exec \
    "postgres" "-c" "ALTER DATABASE \"somedb\" OWNER TO \"someowner\""
  mktest::assert_stub_not_called postgres::_psql_exec "postgres" "-c" "CREATE DATABASE \"somedb\""
}

# --- postgres::ensure_extension ---

@test "ensure_extension in dry-run reports without touching postgres" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_psql_exec
  mktest::stub_function logging::dry_run
  postgres::ensure_extension "somedb" "someext"
  mktest::assert_stub_not_called postgres::_psql_exec
  mktest::assert_stub_called logging::dry_run
}

@test "ensure_extension enables the extension idempotently in the target database" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_psql_exec "somedb" "-c" "CREATE EXTENSION IF NOT EXISTS \"someext\""
  postgres::ensure_extension "somedb" "someext"
  mktest::assert_stub_called postgres::_psql_exec "somedb" "-c" "CREATE EXTENSION IF NOT EXISTS \"someext\""
}

# --- postgres::ensure_role ---

@test "ensure_role in dry-run reports without touching postgres" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_role_exists
  mktest::stub_function postgres::_psql_exec_stdin
  mktest::stub_function logging::dry_run
  postgres::ensure_role "someuser" "somepass"
  mktest::assert_stub_not_called postgres::_role_exists
  mktest::assert_stub_not_called postgres::_psql_exec_stdin
  mktest::assert_stub_called logging::dry_run
}

@test "ensure_role updates the password via stdin (off argv) when the role exists" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_role_exists "someuser"
  # Hand-rolled capture stub: the statement rides stdin, which arg-recording misses.
  postgres::_psql_exec_stdin() { printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/db"; cat > "$BATS_TEST_TMPDIR/sql"; }
  postgres::ensure_role "someuser" "somepass"
  run cat "$BATS_TEST_TMPDIR/db"
  [ "$output" = "postgres" ]
  run cat "$BATS_TEST_TMPDIR/sql"
  [ "$output" = "ALTER ROLE \"someuser\" WITH LOGIN PASSWORD 'somepass'" ]
}

@test "ensure_role creates a login role via stdin (off argv) when missing" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function postgres::_role_exists "someuser"
  postgres::_psql_exec_stdin() { cat > "$BATS_TEST_TMPDIR/sql"; }
  postgres::ensure_role "someuser" "somepass"
  run cat "$BATS_TEST_TMPDIR/sql"
  [ "$output" = "CREATE ROLE \"someuser\" WITH LOGIN PASSWORD 'somepass'" ]
}

@test "ensure_role escapes a single quote in the password so it can't break the literal" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_role_exists "someuser"
  postgres::_psql_exec_stdin() { cat > "$BATS_TEST_TMPDIR/sql"; }
  postgres::ensure_role "someuser" "pa'ss"
  run cat "$BATS_TEST_TMPDIR/sql"
  [ "$output" = "ALTER ROLE \"someuser\" WITH LOGIN PASSWORD 'pa''ss'" ]
}

@test "ensure_role escapes a double quote in the role name so it can't break the identifier" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_role_exists 'we"ird'
  postgres::_psql_exec_stdin() { cat > "$BATS_TEST_TMPDIR/sql"; }
  postgres::ensure_role 'we"ird' 'pw'
  run cat "$BATS_TEST_TMPDIR/sql"
  [ "$output" = $'ALTER ROLE "we""ird" WITH LOGIN PASSWORD \'pw\'' ]
}

# --- postgres::ensure_superuser ---

@test "ensure_superuser creates the predictable postgres superuser" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="fake_createuser" mktest::stub_function postgres::_createuser_path
  mktest::stub_function fake_createuser "-s" "postgres"
  postgres::ensure_superuser
  mktest::assert_stub_called fake_createuser "-s" "postgres"
}

@test "ensure_superuser in dry-run reports without creating a role" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_createuser_path
  mktest::stub_function logging::dry_run
  postgres::ensure_superuser
  mktest::assert_stub_not_called postgres::_createuser_path
  mktest::assert_stub_called logging::dry_run
}

@test "ensure_superuser stays quiet when the superuser already exists" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="fake_createuser" mktest::stub_function postgres::_createuser_path
  STUB_RETURN=1 mktest::stub_function fake_createuser "-s" "postgres"
  postgres::ensure_superuser
  mktest::assert_stub_not_called logging::success
}

# --- postgres::ensure_extension_available ---

@test "ensure_extension_available dispatches the ensure_extension_available seam" {
  mktest::stub_function postgres::_dispatch "ensure_extension_available" "vector"
  postgres::ensure_extension_available "vector"
  mktest::assert_stub_called postgres::_dispatch "ensure_extension_available" "vector"
}

# --- postgres::_request_shape_error (pure jq shape check) ---

@test "_request_shape_error accepts a well-formed request" {
  run postgres::_request_shape_error '[{"version":"18","port":"5432"},{"version":"17","port":"5433"}]'
  [ -z "$output" ]
}

@test "_request_shape_error rejects an entry missing its port" {
  run postgres::_request_shape_error '[{"version":"18"}]'
  [[ "$output" == *"both a version and a port"* ]]
}

@test "_request_shape_error rejects a duplicated version" {
  run postgres::_request_shape_error '[{"version":"18","port":"5432"},{"version":"18","port":"5433"}]'
  [[ "$output" == *"version appears more than once"* ]]
}

@test "_request_shape_error rejects a duplicated port" {
  run postgres::_request_shape_error '[{"version":"18","port":"5432"},{"version":"17","port":"5432"}]'
  [[ "$output" == *"port appears more than once"* ]]
}

@test "_request_shape_error rejects a request with nothing pinned to 5432" {
  run postgres::_request_shape_error '[{"version":"18","port":"5433"}]'
  [[ "$output" == *"5432"* ]]
}

# --- postgres::_requested_versions ---

@test "_requested_versions reads the versions array from config" {
  STUB_OUTPUT='the-versions-array' \
    mktest::stub_function config::get "module.postgres.versions"
  run postgres::_requested_versions
  [ "$output" = 'the-versions-array' ]
}

# --- postgres::_assert_valid_request ---

@test "_assert_valid_request passes a well-formed request" {
  STUB_OUTPUT="" mktest::stub_function postgres::_request_shape_error "the-array"
  mktest::stub_function lifecycle::fail
  postgres::_assert_valid_request "the-array"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_valid_request fails with the shape error message" {
  STUB_OUTPUT="no requested version is pinned to port 5432" \
    mktest::stub_function postgres::_request_shape_error "the-array"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::_assert_valid_request "the-array"
  [ "$status" -ne 0 ]
  MATCH="pinned to port 5432" mktest::assert_stub_called lifecycle::fail
}

# --- postgres::_requested_version_rows ---

@test "_requested_version_rows decodes the versions table into version-tab-port rows" {
  run postgres::_requested_version_rows '[{"version":"17","port":"5432"},{"version":"14","port":"5433"}]'
  [ "${lines[0]}" = $'17\t5432' ]
  [ "${lines[1]}" = $'14\t5433' ]
}

# --- postgres::_satisfier ---

@test "_satisfier resolves the active satisfier for the postgres capability" {
  STUB_OUTPUT="postgres_fake" mktest::stub_function modules::capability_satisfier "postgres"
  run postgres::_satisfier
  [ "$output" = "postgres_fake" ]
}

# --- postgres::_dispatch ---

@test "_dispatch forwards a seam and its args to the active satisfier" {
  STUB_OUTPUT="postgres_fake" mktest::stub_function postgres::_satisfier
  postgres_fake::some_seam() { printf 'ran:%s\n' "$1"; }
  run postgres::_dispatch some_seam "an-arg"
  [ "$output" = "ran:an-arg" ]
}

# --- postgres::_db_exists ---

@test "_db_exists is true when the catalog query returns a row" {
  STUB_OUTPUT="1" mktest::stub_function postgres::_psql_exec \
    "postgres" "-tAc" "SELECT 1 FROM pg_database WHERE datname = 'somedb'"
  postgres::_db_exists "somedb"
}

@test "_db_exists is false when the catalog query returns nothing" {
  STUB_OUTPUT="" mktest::stub_function postgres::_psql_exec \
    "postgres" "-tAc" "SELECT 1 FROM pg_database WHERE datname = 'somedb'"
  run ! postgres::_db_exists "somedb"
}

# --- postgres::_role_exists ---

@test "_role_exists is true when the catalog query returns a row" {
  STUB_OUTPUT="1" mktest::stub_function postgres::_psql_exec \
    "postgres" "-tAc" "SELECT 1 FROM pg_roles WHERE rolname = 'someuser'"
  postgres::_role_exists "someuser"
}

@test "_role_exists is false when the catalog query returns nothing" {
  STUB_OUTPUT="" mktest::stub_function postgres::_psql_exec \
    "postgres" "-tAc" "SELECT 1 FROM pg_roles WHERE rolname = 'someuser'"
  run ! postgres::_role_exists "someuser"
}

# --- postgres::_psql_exec ---

@test "_psql_exec runs psql with no rc file, quietly, as the postgres superuser" {
  STUB_OUTPUT="fake_psql" mktest::stub_function postgres::_psql_path
  mktest::stub_function fake_psql
  postgres::_psql_exec "somedb" "-tAc" "some query"
  mktest::assert_stub_called fake_psql "-X" "-q" "-U" "postgres" "-d" "somedb" "-tAc" "some query"
}

# --- postgres::_psql_exec_stdin ---

@test "_psql_exec_stdin runs psql with the statement on stdin (no -c), as the postgres superuser" {
  STUB_OUTPUT="fake_psql" mktest::stub_function postgres::_psql_path
  fake_psql() { echo "$*" > "$BATS_TEST_TMPDIR/args"; cat > "$BATS_TEST_TMPDIR/in"; }
  printf 'SELECT 1' | postgres::_psql_exec_stdin somedb
  run cat "$BATS_TEST_TMPDIR/args"
  [ "$output" = "-X -q -U postgres -d somedb" ]
  run cat "$BATS_TEST_TMPDIR/in"
  [ "$output" = "SELECT 1" ]
}

# --- postgres::_psql_path ---

@test "_psql_path resolves psql inside the resolved instance's bin directory" {
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::_bin_dir
  run postgres::_psql_path
  [ "$output" = "/fake/bin/psql" ]
}

# --- postgres::_createuser_path ---

@test "_createuser_path resolves createuser inside the resolved instance's bin directory" {
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::_bin_dir
  run postgres::_createuser_path
  [ "$output" = "/fake/bin/createuser" ]
}

# --- postgres::_bin_dir ---

@test "_bin_dir dispatches the bin_dir seam" {
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::_dispatch "bin_dir"
  run postgres::_bin_dir
  [ "$output" = "/fake/bin" ]
}

# --- postgres::_datadir_port ---
# (postgres::_port_in_use is a thin /dev/tcp substrate probe — verified live, not
# unit-tested; its callers' decisions are covered by stubbing it.)

@test "_datadir_port reads the serving port from a running cluster's postmaster.pid" {
  local datadir="$BATS_TEST_TMPDIR/var-17"; mkdir -p "$datadir"
  # Line 1 is a live PID (this test process) so the liveness check passes.
  printf '%s\n%s\n1700000000\n5433\n/tmp\nlocalhost\n  1234567 0\n' "$$" "$datadir" \
    > "$datadir/postmaster.pid"
  run postgres::_datadir_port "$datadir"
  [ "$output" = "5433" ]
}

@test "_datadir_port is nonzero when the cluster is not running (no postmaster.pid)" {
  local datadir="$BATS_TEST_TMPDIR/var-17"; mkdir -p "$datadir"
  run postgres::_datadir_port "$datadir"
  [ "$status" -ne 0 ]
}

@test "_datadir_port treats a stale postmaster.pid (dead PID) as not running" {
  local datadir="$BATS_TEST_TMPDIR/var-17"; mkdir -p "$datadir"
  # A crash leaves the pidfile behind with a PID no longer alive. 2147483646 exceeds
  # pid_max on macOS and Linux, so it is never a live process.
  printf '2147483646\n%s\n1700000000\n5433\n/tmp\nlocalhost\n  1234567 0\n' "$datadir" \
    > "$datadir/postmaster.pid"
  run ! postgres::_datadir_port "$datadir"
}
