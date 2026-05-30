#!/usr/bin/env bats
# Tests for lib/machinekit/lifecycle.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/lifecycle.sh
  source "$MACHINEKIT_DIR/lib/machinekit/lifecycle.sh"
  # Isolate lock paths to this test's temp dir.
  export TMPDIR="$BATS_TEST_TMPDIR"

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::warn
  mktest::stub_function logging::error
}

# --- lifecycle::register_cleanup / lifecycle::run_cleanup ---

@test "register_cleanup adds function to cleanup chain and sets the EXIT trap" {
  lifecycle::register_cleanup my_cleanup_fn
  last_idx=$(( ${#MK_CLEANUP_FUNCS[@]} - 1 ))
  [ "${MK_CLEANUP_FUNCS[$last_idx]}" = "my_cleanup_fn" ]
  local trap_action
  trap_action=$(trap -p EXIT)
  [[ "$trap_action" == *"lifecycle::run_cleanup"* ]]
}

@test "run_cleanup calls registered functions in LIFO order" {
  order_file="$BATS_TEST_TMPDIR/order.txt"
  _mk_test_cleanup_first()  { printf 'first\n'  >> "$order_file"; }
  _mk_test_cleanup_second() { printf 'second\n' >> "$order_file"; }
  lifecycle::register_cleanup _mk_test_cleanup_first
  lifecycle::register_cleanup _mk_test_cleanup_second
  lifecycle::run_cleanup
  MK_CLEANUP_FUNCS=()  # prevent the EXIT trap from re-running them
  [ "$(sed -n '1p' "$order_file")" = "second" ]
  [ "$(sed -n '2p' "$order_file")" = "first" ]
}

@test "run_cleanup is silent when no functions are registered" {
  MK_CLEANUP_FUNCS=()
  lifecycle::run_cleanup
}

# --- lifecycle::acquire_lock ---

@test "acquire_lock creates lock dir and claims it" {
  mktest::stub_function lifecycle::_claim_lock
  lifecycle::acquire_lock
  lock_dir="$BATS_TEST_TMPDIR/machinekit-apply-${UID}.lock"
  [ -d "$lock_dir" ]
  mktest::assert_stub_called lifecycle::_claim_lock
}

@test "acquire_lock fails with a message including the holder PID when lock is held by a live process" {
  # Set up a live-held lock directly — avoids depending on _claim_lock for precondition setup.
  lock_dir="$BATS_TEST_TMPDIR/machinekit-apply-${UID}.lock"
  mkdir "$lock_dir"
  printf '%s\n' "$$" > "$lock_dir/pid"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! lifecycle::acquire_lock
  MATCH="already running" mktest::assert_stub_called lifecycle::fail
  MATCH="PID $$" mktest::assert_stub_called lifecycle::fail
}

@test "acquire_lock takes over a stale lock from a dead process" {
  mktest::stub_function lifecycle::_claim_lock
  lock_dir="$BATS_TEST_TMPDIR/machinekit-apply-${UID}.lock"
  mkdir "$lock_dir"
  # Start a no-op subshell, record its PID, wait for it to die.
  ( exit 0 ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$lock_dir/pid"
  mktest::stub_function lifecycle::_take_over_stale_lock "$dead_pid"
  lifecycle::acquire_lock
  mktest::assert_stub_called lifecycle::_take_over_stale_lock "$dead_pid"
}

# --- lifecycle::release_lock ---

@test "release_lock removes the lock dir" {
  mktest::stub_function lifecycle::_claim_lock
  lifecycle::acquire_lock
  lock_dir="$BATS_TEST_TMPDIR/machinekit-apply-${UID}.lock"
  lifecycle::release_lock
  [ ! -d "$lock_dir" ]
}

@test "release_lock is a no-op when no lock is held" {
  _MK_LOCK_DIR=""
  lifecycle::release_lock
}

# --- lifecycle::_claim_lock ---

@test "_claim_lock fails with an internal error message when the lock dir does not exist" {
  _MK_LOCK_DIR=""
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! lifecycle::_claim_lock
  MATCH="internal error" mktest::assert_stub_called lifecycle::fail
}

@test "_claim_lock writes current PID and registers cleanup" {
  mktest::stub_function lifecycle::register_cleanup "lifecycle::release_lock"
  _MK_LOCK_DIR="$BATS_TEST_TMPDIR/claim-test.lock"
  mkdir "$_MK_LOCK_DIR"
  lifecycle::_claim_lock
  stored_pid=$(< "$_MK_LOCK_DIR/pid")
  [ "$stored_pid" = "$$" ]
  mktest::assert_stub_called lifecycle::register_cleanup "lifecycle::release_lock"
}

# --- lifecycle::_take_over_stale_lock ---

@test "_take_over_stale_lock removes old dir, reclaims with current PID, and warns about the dead process" {
  mktest::stub_function lifecycle::register_cleanup "lifecycle::release_lock"
  _MK_LOCK_DIR="$BATS_TEST_TMPDIR/takeover-test.lock"
  mkdir "$_MK_LOCK_DIR"
  lifecycle::_take_over_stale_lock 12345
  [ -d "$_MK_LOCK_DIR" ]
  stored_pid=$(< "$_MK_LOCK_DIR/pid")
  [ "$stored_pid" = "$$" ]
  MATCH="12345" mktest::assert_stub_called logging::warn
}

@test "_take_over_stale_lock fails when mkdir loses the race after removing the stale lock" {
  _MK_LOCK_DIR="$BATS_TEST_TMPDIR/race-test.lock"
  mkdir "$_MK_LOCK_DIR"
  STUB_RETURN=1 mktest::stub_function mkdir "$_MK_LOCK_DIR"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! lifecycle::_take_over_stale_lock 12345
  MATCH="Lost lock race" mktest::assert_stub_called lifecycle::fail
}

# --- lifecycle::fail ---

@test "fail exits 1 and reports the message via logging::fail" {
  mktest::stub_function logging::fail
  run ! lifecycle::fail "something went wrong"
  [ "$status" -eq 1 ]
  mktest::assert_stub_called logging::fail "something went wrong"
}

@test "fail exits without logging when called with no arguments" {
  mktest::stub_function logging::fail
  run ! lifecycle::fail
  [ "$status" -eq 1 ]
  mktest::assert_stub_not_called logging::fail
}
