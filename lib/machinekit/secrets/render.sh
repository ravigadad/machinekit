#!/usr/bin/env bash
# secrets render — the human view of the `list` inventory: an aligned, colored
# table of the secrets the active modules declare, plus a separate flagged list of
# pool files no active module recognizes.
[ -n "${_MK_SECRETS_RENDER_LOADED:-}" ] && return 0
_MK_SECRETS_RENDER_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../secrets.sh"

# secrets::render — a table of the declared secrets, then — separately — any pool
# secrets no active module recognizes. Nothing to show is a plain message.
secrets::render() {
  local rows orphans
  rows="$(secrets::inventory)"
  orphans="$(secrets::orphans)"

  if [ -z "$rows" ] && [ -z "$orphans" ]; then
    logging::info "No pool secrets are needed or present for the active modules."
    return 0
  fi

  [ -n "$rows" ] && secrets::render::_table "$rows"
  [ -n "$orphans" ] && secrets::render::_orphans "$orphans"
  return 0
}

# A blank-prefixed table with bold headers, hand-aligned (column -t can't be used
# — the per-row ANSI codes would throw off its width math). Each row is colored by
# how it stands: green when already in the pool, yellow when absent but machinekit
# will generate it, red when it is a blocker (absent, required, not generated).
secrets::render::_table() {
  local rows="$1" path required can_be_generated state in_pool req_col gen_col color line
  # Decide color here, where stdout is the command's real stdout — never inside a
  # $() (there fd 1 is the capture pipe, so [ -t 1 ] would always be false).
  local bold="" reset="" green="" yellow="" red=""
  if secrets::render::_color_enabled; then
    bold=$'\033[1m'; reset=$'\033[0m'
    green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'
  fi

  local secret_width=6 # len("SECRET")
  while IFS=$'\t' read -r path _; do
    [ "${#path}" -gt "$secret_width" ] && secret_width="${#path}"
  done <<< "$rows"

  printf '\n'
  printf -v line '%-*s  %-7s  %-8s  %-19s' \
    "$secret_width" SECRET "IN POOL" REQUIRED "GENERATE IF MISSING"
  printf '%s%s%s\n' "$bold" "$line" "$reset"

  while IFS=$'\t' read -r path required can_be_generated state; do
    [ -n "$path" ] || continue
    if [ "$state" = provided ]; then in_pool=yes; else in_pool=no; fi
    if [ "$required" = true ]; then req_col=yes; else req_col=no; fi
    if [ "$can_be_generated" = true ]; then gen_col=yes; else gen_col=no; fi
    # Green once it's in the pool; otherwise yellow if machinekit will generate it,
    # red if it's a required blocker, and uncolored if it's merely optional.
    if [ "$state" = provided ]; then
      color="$green"
    elif [ "$can_be_generated" = true ]; then
      color="$yellow"
    elif [ "$required" = true ]; then
      color="$red"
    else
      color=""
    fi
    printf -v line '%-*s  %-7s  %-8s  %-19s' \
      "$secret_width" "$path" "$in_pool" "$req_col" "$gen_col"
    printf '%s%s%s\n' "$color" "$line" "$reset"
  done <<< "$rows"
}

# The strays: pool files no active module claims. Not a table — a flagged list,
# since the actionable thing is to check each name for a typo or staleness.
secrets::render::_orphans() {
  local orphans="$1" path yellow="" reset=""
  if secrets::render::_color_enabled; then yellow=$'\033[33m'; reset=$'\033[0m'; fi
  printf '\n%sUnrecognized secrets in the pool — not used by any active module.%s\n' "$yellow" "$reset"
  printf 'Check each for a typo or a stale entry:\n'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '  %s\n' "$path"
  done <<< "$orphans"
}

# True when stdout is a color-capable TTY (so piping the table into a pager or
# grep stays clean). Honors NO_COLOR. Must be called from the function that writes
# to stdout, not via $() — a command substitution's fd 1 is a pipe, not the TTY.
secrets::render::_color_enabled() {
  [ -z "${NO_COLOR:-}" ] && input::stdout_is_tty
}
