#!/usr/bin/env bash
# bash_floor — the single source of machinekit's minimum bash version, plus the
# predicate and entry guard built on it. The floor is 5.3 so modern code may use
# ${ cmd; } inline command substitution.
#
# Pure-3.2, shared by two pure-3.2 callers: lib/bootstrap/bash.sh (which resolves a
# qualifying bash) and each libexec impl (which guards against being run directly
# under an old one). Keep this file 3.2-safe forever.
[ -n "${_MK_BASH_FLOOR_LOADED:-}" ] && return 0
_MK_BASH_FLOOR_LOADED=1

BASH_FLOOR_MAJOR=5
BASH_FLOOR_MINOR=3

# True if MAJOR.MINOR meets or exceeds the floor.
bash_floor::meets() {
  local major="$1" minor="$2"
  [ "$major" -gt "$BASH_FLOOR_MAJOR" ] && return 0
  [ "$major" -eq "$BASH_FLOOR_MAJOR" ] && [ "$minor" -ge "$BASH_FLOOR_MINOR" ]
}

# Exit with a clear message when the running bash is below the floor. The libexec
# impls call this first so a direct invocation under an old bash fails cleanly
# instead of throwing a syntax error on the modern code below it.
bash_floor::guard() {
  bash_floor::meets "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" && return 0
  printf 'machinekit: bash >= %s.%s required; run via the machinekit command, not this file directly.\n' \
    "$BASH_FLOOR_MAJOR" "$BASH_FLOOR_MINOR" >&2
  exit 1
}
