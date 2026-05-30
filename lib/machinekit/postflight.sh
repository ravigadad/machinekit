#!/usr/bin/env bash
# Post-apply summary output. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_POSTFLIGHT_LOADED:-}" ] && return 0
_MK_POSTFLIGHT_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/input.sh"

postflight::run() {
  printf '\n'
  if input::is_dry_run; then
    logging::dry_run "dry run complete — no changes were made to this machine."
  else
    logging::success "machinekit apply complete."
    postflight::_print_exec_hint
  fi
}

postflight::_print_exec_hint() {
  printf '\n'
  logging::info "To pick up shell changes in this session, run:"
  logging::info ""
  logging::info "    exec \$SHELL -l"
  logging::info ""
  logging::info "This replaces your current shell with a fresh one, so any"
  logging::info "interactive state (unexported variables, ad-hoc aliases,"
  logging::info "background jobs tied to this shell) is lost. Open a new"
  logging::info "terminal instead if you'd rather keep that state."
}
