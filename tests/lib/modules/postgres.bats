#!/usr/bin/env bats
# Tests for lib/modules/postgres.sh (hooks, provisioning, consumer API).
# Read-only introspection is tested in postgres/introspect.bats; container
# access in postgres/access.bats.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/postgres.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::success
}

# --- postgres::install (dispatch + superuser) ---

@test "install routes to the requested-versions path and ensures the superuser" {
  STUB_OUTPUT='the-version-array' mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres::_install_requested
  mktest::stub_function postgres::_install_default
  mktest::stub_function postgres::_ensure_superuser
  postgres::install
  mktest::assert_stub_called postgres::_install_requested 'the-version-array'
  mktest::assert_stub_not_called postgres::_install_default
  mktest::assert_stub_called postgres::_ensure_superuser
}

@test "install routes to the default path when no versions are configured" {
  STUB_RETURN=1 mktest::stub_function postgres::_requested_versions
  mktest::stub_function postgres::_install_requested
  mktest::stub_function postgres::_install_default
  mktest::stub_function postgres::_ensure_superuser
  postgres::install
  mktest::assert_stub_called postgres::_install_default
  mktest::assert_stub_not_called postgres::_install_requested
  mktest::assert_stub_called postgres::_ensure_superuser
}

# --- postgres::post_apply ---

@test "post_apply delegates to access configuration" {
  mktest::stub_function postgres::access::configure
  postgres::post_apply
  mktest::assert_stub_called postgres::access::configure
}

# --- postgres::version ---

@test "version reports the resolved instance major" {
  STUB_OUTPUT="18" mktest::stub_function postgres::introspect::instance_version
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
  mktest::stub_function postgres::_psql_exec
  mktest::stub_function logging::dry_run
  postgres::ensure_role "someuser" "somepass"
  mktest::assert_stub_not_called postgres::_role_exists
  mktest::assert_stub_not_called postgres::_psql_exec
  mktest::assert_stub_called logging::dry_run
}

@test "ensure_role is a no-op when the role already exists" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_role_exists "someuser"
  mktest::stub_function postgres::_psql_exec
  postgres::ensure_role "someuser" "somepass"
  mktest::assert_stub_not_called postgres::_psql_exec
}

@test "ensure_role creates a login role with the password when missing" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function postgres::_role_exists "someuser"
  mktest::stub_function postgres::_psql_exec \
    "postgres" "-c" "CREATE ROLE \"someuser\" WITH LOGIN PASSWORD 'somepass'"
  postgres::ensure_role "someuser" "somepass"
  mktest::assert_stub_called postgres::_psql_exec \
    "postgres" "-c" "CREATE ROLE \"someuser\" WITH LOGIN PASSWORD 'somepass'"
}

# --- postgres::_install_requested ---

@test "_install_requested validates the request, then ensures each version" {
  STUB_OUTPUT="" mktest::stub_function postgres::_request_shape_error "the-version-array"
  mktest::stub_function postgres::_assert_compatible_with_installed
  mktest::stub_function postgres::_ensure_requested
  postgres::_install_requested "the-version-array"
  mktest::assert_stub_called_in_order postgres::_assert_compatible_with_installed "the-version-array"
  mktest::assert_stub_called_in_order postgres::_ensure_requested "the-version-array"
}

@test "_install_requested fails on an invalid request shape before ensuring anything" {
  STUB_OUTPUT="no requested version is pinned to port 5432" \
    mktest::stub_function postgres::_request_shape_error "the-version-array"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function postgres::_assert_compatible_with_installed
  mktest::stub_function postgres::_ensure_requested
  run postgres::_install_requested "the-version-array"
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called postgres::_assert_compatible_with_installed
  mktest::assert_stub_not_called postgres::_ensure_requested
}

# --- postgres::_install_default ---

@test "_install_default uses the existing 5432 instance instead of installing" {
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::instance_version
  mktest::stub_function postgres::_ensure_running "17"
  mktest::stub_function postgres::_install_on_port
  postgres::_install_default
  mktest::assert_stub_called postgres::_ensure_running "17"
  mktest::assert_stub_not_called postgres::_install_on_port
}

@test "_install_default installs the latest major on 5432 when nothing is there" {
  STUB_RETURN=1 mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres::introspect::latest_available_version
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_installed "18"
  mktest::stub_function postgres::_install_on_port "18" "5432"
  postgres::_install_default
  mktest::assert_stub_called postgres::_install_on_port "18" "5432"
}

@test "_install_default fails when the latest major already has a cluster on another port" {
  STUB_RETURN=1 mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres::introspect::latest_available_version
  mktest::stub_function postgres::introspect::is_installed "18"
  mktest::stub_function postgres::introspect::is_initialized "18"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function postgres::_install_on_port
  run postgres::_install_default
  [ "$status" -ne 0 ]
  MATCH="non-5432 port" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called postgres::_install_on_port
}

@test "_install_default fails when the latest major is installed but never initialized" {
  STUB_RETURN=1 mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="18" mktest::stub_function postgres::introspect::latest_available_version
  mktest::stub_function postgres::introspect::is_installed "18"
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_initialized "18"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function postgres::_install_on_port
  run postgres::_install_default
  [ "$status" -ne 0 ]
  MATCH="never initialized" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called postgres::_install_on_port
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

# --- postgres::_assert_compatible_with_installed ---

@test "_assert_compatible_with_installed passes when installs match the request" {
  local requested='[{"version":"17","port":"5432"},{"version":"14","port":"5433"}]'
  STUB_OUTPUT=$'17\n14' mktest::stub_function postgres::introspect::installed_versions
  mktest::stub_function postgres::introspect::is_initialized "17"
  mktest::stub_function postgres::introspect::is_initialized "14"
  STUB_OUTPUT="5432" mktest::stub_function postgres::introspect::configured_port "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres::introspect::configured_port "14"
  mktest::stub_function lifecycle::fail
  postgres::_assert_compatible_with_installed "$requested"
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version is absent from the request" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT=$'17\n14' mktest::stub_function postgres::introspect::installed_versions
  mktest::stub_function postgres::introspect::is_initialized
  STUB_OUTPUT="5432" mktest::stub_function postgres::introspect::configured_port
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="not in the requested" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version was never initialized" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::installed_versions
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_initialized "17"
  mktest::stub_function postgres::introspect::configured_port "17"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="never initialized" mktest::assert_stub_called lifecycle::fail
}

@test "_assert_compatible_with_installed fails when an installed version's port differs from the request" {
  local requested='[{"version":"17","port":"5432"}]'
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::installed_versions
  mktest::stub_function postgres::introspect::is_initialized "17"
  STUB_OUTPUT="5433" mktest::stub_function postgres::introspect::configured_port "17"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run postgres::_assert_compatible_with_installed "$requested"
  [ "$status" -ne 0 ]
  MATCH="will not change.*port" mktest::assert_stub_called lifecycle::fail
}

# --- postgres::_ensure_requested ---

@test "_ensure_requested starts installed versions and installs missing ones on their ports" {
  local requested='[{"version":"17","port":"5432"},{"version":"14","port":"5433"}]'
  mktest::stub_function postgres::introspect::is_installed "17"
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_installed "14"
  mktest::stub_function postgres::_ensure_running "17"
  mktest::stub_function postgres::_install_on_port "14" "5433"
  postgres::_ensure_requested "$requested"
  mktest::assert_stub_called postgres::_ensure_running "17"
  mktest::assert_stub_called postgres::_install_on_port "14" "5433"
}

# --- postgres::_install_on_port ---

@test "_install_on_port installs and starts the 5432 instance without touching its port" {
  STUB_OUTPUT="postgresql@18" mktest::stub_function postgres::introspect::formula "18"
  mktest::stub_function brew::install_formula "postgresql@18"
  mktest::stub_function postgres::_set_port
  mktest::stub_function postgres::_start "18"
  postgres::_install_on_port 18 5432
  mktest::assert_stub_called_in_order brew::install_formula "postgresql@18"
  mktest::assert_stub_called_in_order postgres::_start "18"
  mktest::assert_stub_not_called postgres::_set_port
}

@test "_install_on_port installs an alt-port version, sets its port, then starts it" {
  STUB_OUTPUT="postgresql@14" mktest::stub_function postgres::introspect::formula "14"
  mktest::stub_function brew::install_formula "postgresql@14"
  mktest::stub_function postgres::_set_port "14" "5433"
  mktest::stub_function postgres::_start "14"
  postgres::_install_on_port 14 5433
  mktest::assert_stub_called_in_order brew::install_formula "postgresql@14"
  mktest::assert_stub_called_in_order postgres::_set_port "14" "5433"
  mktest::assert_stub_called_in_order postgres::_start "14"
}

# --- postgres::_set_port ---

@test "_set_port sets the port in postgresql.conf, preserving other lines and staying idempotent" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  local datadir="$BATS_TEST_TMPDIR/d"; mkdir -p "$datadir"
  printf '#port = 5432\nmax_connections = 100\n' > "$datadir/postgresql.conf"
  STUB_OUTPUT="$datadir" mktest::stub_function postgres::introspect::data_dir "14"
  postgres::_set_port 14 5433
  postgres::_set_port 14 5433
  run grep -c '^port = 5433$' "$datadir/postgresql.conf"
  [ "$output" = "1" ]
  run grep -c '^max_connections = 100$' "$datadir/postgresql.conf"
  [ "$output" = "1" ]
}

@test "_set_port in dry-run reports without reading or writing the config" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function logging::dry_run
  mktest::stub_function postgres::introspect::data_dir
  postgres::_set_port 14 5433
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called postgres::introspect::data_dir
}

# --- postgres::_ensure_running ---

@test "_ensure_running leaves a running instance alone" {
  mktest::stub_function postgres::introspect::is_running "17"
  mktest::stub_function postgres::_start
  postgres::_ensure_running 17
  mktest::assert_stub_not_called postgres::_start
}

@test "_ensure_running starts a stopped instance" {
  STUB_RETURN=1 mktest::stub_function postgres::introspect::is_running "17"
  mktest::stub_function postgres::_start "17"
  postgres::_ensure_running 17
  mktest::assert_stub_called postgres::_start "17"
}

# --- postgres::_start ---

@test "_start starts the resolved formula's service" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="postgresql@17" mktest::stub_function postgres::introspect::formula "17"
  mktest::stub_function brew::start_service "postgresql@17"
  postgres::_start 17
  mktest::assert_stub_called brew::start_service "postgresql@17"
}

@test "_start in dry-run reports instead of starting the daemon" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function brew::start_service
  mktest::stub_function logging::dry_run
  postgres::_start 17
  mktest::assert_stub_not_called brew::start_service
  mktest::assert_stub_called logging::dry_run
}

# --- postgres::_restart ---

@test "_restart restarts the resolved formula's service" {
  STUB_OUTPUT="postgresql@17" mktest::stub_function postgres::introspect::formula "17"
  mktest::stub_function brew::restart_service "postgresql@17"
  postgres::_restart 17
  mktest::assert_stub_called brew::restart_service "postgresql@17"
}

# --- postgres::_ensure_superuser ---

@test "_ensure_superuser creates the predictable postgres superuser" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="fake_createuser" mktest::stub_function postgres::_createuser_path
  mktest::stub_function fake_createuser "-s" "postgres"
  postgres::_ensure_superuser
  mktest::assert_stub_called fake_createuser "-s" "postgres"
}

@test "_ensure_superuser in dry-run reports without creating a role" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postgres::_createuser_path
  mktest::stub_function logging::dry_run
  postgres::_ensure_superuser
  mktest::assert_stub_not_called postgres::_createuser_path
  mktest::assert_stub_called logging::dry_run
}

@test "_ensure_superuser stays quiet when the superuser already exists" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="fake_createuser" mktest::stub_function postgres::_createuser_path
  STUB_RETURN=1 mktest::stub_function fake_createuser "-s" "postgres"
  postgres::_ensure_superuser
  mktest::assert_stub_not_called logging::success
}

# --- postgres::_createuser_path ---

@test "_createuser_path resolves createuser inside the resolved instance's bin directory" {
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::introspect::bin_dir "17"
  run postgres::_createuser_path
  [ "$output" = "/fake/bin/createuser" ]
}

# --- postgres::_requested_versions ---

@test "_requested_versions reads the versions array from config" {
  STUB_OUTPUT='the-versions-array' \
    mktest::stub_function config::get "module.postgres.versions"
  run postgres::_requested_versions
  [ "$output" = 'the-versions-array' ]
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

# --- postgres::_psql_path ---

@test "_psql_path resolves psql inside the resolved instance's bin directory" {
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="/fake/bin" mktest::stub_function postgres::introspect::bin_dir "17"
  run postgres::_psql_path
  [ "$output" = "/fake/bin/psql" ]
}
