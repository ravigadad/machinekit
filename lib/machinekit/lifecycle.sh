#!/usr/bin/env bash
# Cleanup hook chain, lock management, and hard-exit helper. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_LIFECYCLE_LOADED:-}" ] && return 0
_MK_LIFECYCLE_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

# Cleanup hook chain. Functions registered via lifecycle::register_cleanup run when
# the script exits — clean, errored, or signaled (anything that fires the
# EXIT trap). Runs in reverse registration order (LIFO, defer-style).
# Each cleanup function should be idempotent and silent on no-op; errors
# are swallowed so one broken cleanup doesn't prevent others.
MK_CLEANUP_FUNCS=()

lifecycle::register_cleanup() {
  MK_CLEANUP_FUNCS+=("$1")
  # Idempotent: re-setting the trap to the same handler is harmless.
  trap 'lifecycle::run_cleanup' EXIT
}

lifecycle::run_cleanup() {
  local i
  for (( i=${#MK_CLEANUP_FUNCS[@]}-1; i>=0; i-- )); do
    "${MK_CLEANUP_FUNCS[i]}" 2>/dev/null || true
  done
}

# Module-level state shared between acquire and release across the cleanup trap boundary.
_MK_LOCK_DIR=""

# Acquire a per-user exclusive lock so two concurrent applies don't stomp each
# other. Uses mkdir (atomic on POSIX filesystems) rather than flock (not
# available by default on macOS). Writes $$ into the lock so a stale lock from
# a crashed run is detected and removed automatically on the next invocation.
lifecycle::acquire_lock() {
  _MK_LOCK_DIR="${TMPDIR:-/tmp}/machinekit-apply-${UID}.lock"

  if mkdir "$_MK_LOCK_DIR" 2>/dev/null; then
    lifecycle::_claim_lock
    return 0
  fi

  local holder_pid=""
  if [ -f "$_MK_LOCK_DIR/pid" ]; then
    holder_pid=$(< "$_MK_LOCK_DIR/pid")
  fi

  if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
    lifecycle::_take_over_stale_lock "$holder_pid"
    return 0
  fi

  local msg="Another machinekit apply is already running"
  [ -n "$holder_pid" ] && msg="$msg (PID $holder_pid)"
  lifecycle::fail "$msg. If it's not running, remove: $_MK_LOCK_DIR"
}

# Precondition: _MK_LOCK_DIR has just been created by this process (fresh or after stale removal).
lifecycle::_claim_lock() {
  [ -d "$_MK_LOCK_DIR" ] || lifecycle::fail "internal error: _claim_lock called but lock dir does not exist: '$_MK_LOCK_DIR'"
  printf '%s\n' "$$" > "$_MK_LOCK_DIR/pid"
  lifecycle::register_cleanup lifecycle::release_lock
}

# Remove a lock left by a dead process and reclaim it.
lifecycle::_take_over_stale_lock() {
  local dead_pid="$1"
  logging::warn "Removing stale lock from PID $dead_pid (process is gone)."
  rm -rf -- "$_MK_LOCK_DIR"
  if mkdir "$_MK_LOCK_DIR" 2>/dev/null; then
    lifecycle::_claim_lock
  else
    lifecycle::fail "Lost lock race after removing stale lock from PID $dead_pid"
  fi
}

lifecycle::release_lock() {
  [ -n "$_MK_LOCK_DIR" ] || return 0
  rm -rf -- "$_MK_LOCK_DIR"
  _MK_LOCK_DIR=""
}

lifecycle::fail() {
  [ $# -gt 0 ] && logging::fail "$@"
  exit 1
}