#!/usr/bin/env bash
# bootstrap::bash — resolve a bash that meets machinekit's version floor, installing
# Homebrew's bash when the running interpreter is too old. Sourced by bin/machinekit
# (the pure-3.2 entry) before any modern lib; keep this file 3.2-safe forever.
#
# The floor is 5.3 so the modern code can use ${ cmd; } inline command
# substitution. ensure_modern_bash prints the path to a qualifying bash on stdout
# (logs go to stderr via bootstrap::brew), which the dispatcher captures and execs
# the real impl under.
[ -n "${_MK_BOOTSTRAP_BASH_LOADED:-}" ] && return 0
_MK_BOOTSTRAP_BASH_LOADED=1

_MK_BOOTSTRAP_BASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/bash_floor.sh
source "$_MK_BOOTSTRAP_BASH_DIR/../common/bash_floor.sh"
# shellcheck source=brew.sh
source "$_MK_BOOTSTRAP_BASH_DIR/brew.sh"

# "MAJOR MINOR" of the bash binary at $1, asked of the binary itself.
bootstrap::bash::_version_of() {
  # shellcheck disable=SC2016  # the child bash expands BASH_VERSINFO, not us
  "$1" -c 'printf "%s %s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'
}

# Whether the currently-running bash meets the floor. Its own function so the
# orchestrator's branch is stubbable despite reading the BASH_VERSINFO global.
bootstrap::bash::_current_meets_floor() {
  bash_floor::meets "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
}

# Whether the bash binary at $1 meets the floor, asked of the binary itself.
bootstrap::bash::_binary_meets_floor() {
  local pair
  pair="$(bootstrap::bash::_version_of "$1")"
  # shellcheck disable=SC2086  # word-splitting the "MAJOR MINOR" pair into $1 $2 is the point
  set -- $pair
  bash_floor::meets "${1:-0}" "${2:-0}"
}

# Print the path to a bash that meets the floor. MACHINEKIT_BASH overrides the
# search outright (use exactly that bash, never install — failing if it falls
# short). Otherwise the running bash if it qualifies; else install Homebrew's bash
# and return its path — failing if even that falls short.
bootstrap::bash::ensure_modern_bash() {
  if [ -n "${MACHINEKIT_BASH:-}" ]; then
    bootstrap::bash::_binary_meets_floor "$MACHINEKIT_BASH" \
      || bootstrap::brew::_fail "MACHINEKIT_BASH ($MACHINEKIT_BASH) is below the required ${BASH_FLOOR_MAJOR}.${BASH_FLOOR_MINOR}."
    printf '%s\n' "$MACHINEKIT_BASH"
    return 0
  fi
  if bootstrap::bash::_current_meets_floor; then
    printf '%s\n' "$BASH"
    return 0
  fi
  bootstrap::brew::ensure
  local brew_bash
  brew_bash="$(bootstrap::brew::bash_path)"
  # Reuse an already-installed brew bash that meets the floor; reinstalling on
  # every dispatch is a slow, chatty no-op. Only install when it's absent or old.
  if [ ! -x "$brew_bash" ] || ! bootstrap::bash::_binary_meets_floor "$brew_bash"; then
    bootstrap::brew::install_bash
    bootstrap::bash::_binary_meets_floor "$brew_bash" \
      || bootstrap::brew::_fail "installed bash at $brew_bash is below the required ${BASH_FLOOR_MAJOR}.${BASH_FLOOR_MINOR}."
  fi
  printf '%s\n' "$brew_bash"
}
