#!/usr/bin/env bash
# Logging and output helpers. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_LOGGING_LOADED:-}" ] && return 0
_MK_LOGGING_LOADED=1

# Colors are opt-in: only emit escape codes when stderr is interactive and
# NO_COLOR is absent. See https://no-color.org for the spec; setting NO_COLOR
# in a shell profile suppresses color in all compliant tools at once.
logging::_init_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    MK_COLOR_RED=$'\033[31m'
    MK_COLOR_YELLOW=$'\033[33m'
    MK_COLOR_GREEN=$'\033[32m'
    MK_COLOR_BLUE=$'\033[34m'
    MK_COLOR_BOLD=$'\033[1m'
    MK_COLOR_RESET=$'\033[0m'
  else
    MK_COLOR_RED=""
    MK_COLOR_YELLOW=""
    MK_COLOR_GREEN=""
    MK_COLOR_BLUE=""
    MK_COLOR_BOLD=""
    MK_COLOR_RESET=""
  fi
}

logging::_emit() {
  local color="$1" prefix="$2"
  prefix=${prefix:+" $prefix"}
  shift 2
  printf '%s[machinekit]%s%s %s\n' "$color" "$prefix" "$MK_COLOR_RESET" "$*" >&2
}

logging::debug() {
  [ "${MACHINEKIT_VERBOSE:-0}" = "1" ] || return 0
  logging::_emit "$(logging::_color_for_level debug)" "debug:" "$@"
}
logging::info()    { logging::_emit "$(logging::_color_for_level info)"    ""         "$@"; }
logging::warn()    { logging::_emit "$(logging::_color_for_level warn)"    "warning:" "$@"; }
logging::error()   { logging::_emit "$(logging::_color_for_level error)"   "error:"   "$@"; }
logging::success() { logging::_emit "$(logging::_color_for_level success)" "✓"        "$@"; }
logging::dry_run() { logging::_emit "$(logging::_color_for_level dry_run)" "dry-run:" "$@"; }

logging::step() {
  printf '\n' >&2
  logging::_emit "$MK_COLOR_BOLD" "" "${MK_COLOR_BOLD}$*"
}

# Called by lifecycle::fail before exit. Separated from logging::error so this
# layer can evolve independently — e.g. add an "Exiting." trailer or a distinct
# visual treatment — without touching lifecycle.
logging::fail() { logging::error "$@"; }

# Emits a visually distinct block for high-attention messages. Level sets the
# color (same values as the other logging functions). Each line of text — and
# the separator lines — goes through _emit so all output carries [machinekit].
logging::banner() {
  local level="$1" text="$2" color
  color=$(logging::_color_for_level "$level")
  local sep="========================================================"
  printf '\n' >&2
  logging::_emit "$color" "" "$sep"
  while IFS= read -r line; do
    logging::_emit "$color" "" "$line"
  done <<< "$text"
  logging::_emit "$color" "" "$sep"
  printf '\n' >&2
}

logging::_color_for_level() {
  local level="$1" color
  case "$level" in
    debug)   color="$MK_COLOR_BLUE" ;;
    info)    color="$MK_COLOR_BLUE" ;;
    warn)    color="$MK_COLOR_YELLOW" ;;
    error)   color="$MK_COLOR_RED" ;;
    success) color="$MK_COLOR_GREEN" ;;
    dry_run) color="$MK_COLOR_YELLOW" ;;
  esac
  printf "%s\n" "$color"
}

logging::_init_colors
