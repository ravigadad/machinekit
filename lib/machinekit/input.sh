#!/usr/bin/env bash
# Mode detection and interactive input helpers. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_INPUT_LOADED:-}" ] && return 0
_MK_INPUT_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context.sh"

# Resolves and validates interactive mode, failing fast if the configuration is
# contradictory (e.g. --interactive with an unreadable tty).
input::detect_mode() {
  input::is_interactive >/dev/null || true
}

# Returns "true"/"false" and exits 0/1 so callers can use it both as a value
# source and a predicate. Caches the result so tty detection only runs once.
# Blows up early if the context was explicitly set to interactive but the tty
# has since become unreadable - better to fail loud here than silently skip
# prompts later.
input::is_interactive() {
  local val
  if val=$(context::get "mode.interactive" --coerce boolean); then
    if [ "$val" = "true" ] && [ ! -r "${MACHINEKIT_TTY:-/dev/tty}" ]; then
      lifecycle::fail "Interactive mode requires a readable tty at ${MACHINEKIT_TTY:-/dev/tty}"
    fi
    printf '%s\n' "$val"
    [ "$val" = "true" ]
    return
  fi

  if [ -r "${MACHINEKIT_TTY:-/dev/tty}" ]; then val="true"; else val="false"; fi
  context::set "mode.interactive" "$val"
  printf '%s\n' "$val"
  [ "$val" = "true" ]
}

input::is_dry_run() {
  local val
  val=$(context::get "mode.dry_run" --coerce boolean --default false)
  [ "$val" = "true" ]
}

input::command_exists() {
  command -v "$1" >/dev/null 2>&1
}

input::conflict_behavior() {
  if [ -n "${MACHINEKIT_CONFLICT_BEHAVIOR:-}" ]; then
    printf '%s\n' "$MACHINEKIT_CONFLICT_BEHAVIOR"
    return 0
  fi
  local val
  val=$(config::get "conflict_behavior" 2>/dev/null) || true
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  fi
}
