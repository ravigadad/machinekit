#!/usr/bin/env bats
# Tests for lib/modules/postgres/access.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/postgres/access.sh
  source "$MACHINEKIT_DIR/lib/modules/postgres/access.sh"

  mktest::stub_function logging::debug
  mktest::stub_function logging::success
}

# --- postgres::access::configure ---

@test "configure does nothing when no container runtime is active" {
  STUB_RETURN=1 mktest::stub_function modules::capability_active "container_manager"
  mktest::stub_function context::get
  mktest::stub_function postgres::access::_open_for_containers
  postgres::access::configure
  mktest::assert_stub_not_called context::get
  mktest::assert_stub_not_called postgres::access::_open_for_containers
}

@test "configure is a no-op on macOS, where containers reach the host over loopback" {
  mktest::stub_function modules::capability_active "container_manager"
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  mktest::stub_function postgres::access::_open_for_containers
  postgres::access::configure
  mktest::assert_stub_not_called postgres::access::_open_for_containers
}

@test "configure opens access on Linux" {
  mktest::stub_function modules::capability_active "container_manager"
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  mktest::stub_function postgres::access::_open_for_containers
  postgres::access::configure
  mktest::assert_stub_called postgres::access::_open_for_containers
}

# --- postgres::access::_open_for_containers ---

@test "_open_for_containers opens listen, authorizes the subnet, then restarts" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="17" mktest::stub_function postgres::introspect::instance_version
  STUB_OUTPUT="172.30.0.0/16" mktest::stub_function container_manager::container_subnet
  mktest::stub_function postgres::access::_open_listen "17"
  mktest::stub_function postgres::access::_authorize_subnet "17" "172.30.0.0/16"
  mktest::stub_function postgres::_restart "17"
  postgres::access::_open_for_containers
  mktest::assert_stub_called_in_order postgres::access::_open_listen "17"
  mktest::assert_stub_called_in_order postgres::access::_authorize_subnet "17" "172.30.0.0/16"
  mktest::assert_stub_called_in_order postgres::_restart "17"
}

@test "_open_for_containers fails loudly when no instance is resolved" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function postgres::introspect::instance_version
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function container_manager::container_subnet
  run postgres::access::_open_for_containers
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called container_manager::container_subnet
}

@test "_open_for_containers in dry-run reports without touching docker or the config" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function logging::dry_run
  mktest::stub_function container_manager::container_subnet
  mktest::stub_function postgres::access::_open_listen
  mktest::stub_function postgres::_restart
  postgres::access::_open_for_containers
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called container_manager::container_subnet
  mktest::assert_stub_not_called postgres::access::_open_listen
  mktest::assert_stub_not_called postgres::_restart
}

# --- postgres::access::_open_listen ---

@test "_open_listen writes the listen_addresses block to postgresql.conf" {
  STUB_OUTPUT="/fake/d" mktest::stub_function postgres::introspect::data_dir "17"
  mktest::stub_function postgres::access::_write_block \
    "/fake/d/postgresql.conf" "listen_addresses = '*'"
  postgres::access::_open_listen 17
  mktest::assert_stub_called postgres::access::_write_block \
    "/fake/d/postgresql.conf" "listen_addresses = '*'"
}

# --- postgres::access::_authorize_subnet ---

@test "_authorize_subnet writes a scram pg_hba line scoped to the subnet" {
  STUB_OUTPUT="/fake/d" mktest::stub_function postgres::introspect::data_dir "17"
  mktest::stub_function postgres::access::_write_block \
    "/fake/d/pg_hba.conf" "host all all 172.30.0.0/16 scram-sha-256"
  postgres::access::_authorize_subnet 17 "172.30.0.0/16"
  mktest::assert_stub_called postgres::access::_write_block \
    "/fake/d/pg_hba.conf" "host all all 172.30.0.0/16 scram-sha-256"
}

# --- postgres::access::_write_block ---

@test "_write_block writes a marked block idempotently, preserving other lines" {
  local f="$BATS_TEST_TMPDIR/conf"
  printf 'existing = yes\n' > "$f"
  postgres::access::_write_block "$f" "listen_addresses = '*'"
  postgres::access::_write_block "$f" "listen_addresses = '*'"
  run grep -cF "listen_addresses = '*'" "$f"
  [ "$output" = "1" ]
  run grep -c '# >>> machinekit:postgres >>>' "$f"
  [ "$output" = "1" ]
  run grep -c '^existing = yes$' "$f"
  [ "$output" = "1" ]
}

@test "_write_block replaces a stale block rather than appending a second one" {
  local f="$BATS_TEST_TMPDIR/conf"
  : > "$f"
  postgres::access::_write_block "$f" "old = 1"
  postgres::access::_write_block "$f" "new = 2"
  run grep -c '^old = 1$' "$f"
  [ "$output" = "0" ]
  run grep -c '^new = 2$' "$f"
  [ "$output" = "1" ]
}
