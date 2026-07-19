#!/usr/bin/env bash
# Post-apply summary output. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_POSTFLIGHT_LOADED:-}" ] && return 0
_MK_POSTFLIGHT_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/input.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context.sh"

# The two summary groups. Each active module reports facts through one hook per
# group — postflight owns all layout, so the heading and per-module header style
# live here, not in the modules. Kept as constants so a test asserts against the
# same heading/color the walk emits (colors are empty off a TTY; see logging.sh).
_MK_POSTFLIGHT_INFO_HEADING="What machinekit set up"
_MK_POSTFLIGHT_INSTRUCTIONS_HEADING="Next steps"
_MK_POSTFLIGHT_INFO_MODULE_COLOR="$MK_COLOR_GREEN"
_MK_POSTFLIGHT_INSTRUCTIONS_MODULE_COLOR="${MK_COLOR_BOLD}${MK_COLOR_YELLOW}"

postflight::run() {
  printf '\n'
  if input::is_dry_run; then
    logging::dry_run "dry run complete — no changes were made to this machine."
    postflight::_print_baseline
    return 0
  fi
  logging::success "machinekit apply complete."
  postflight::_print_baseline
  postflight::_module_group postflight_info \
    "$_MK_POSTFLIGHT_INFO_HEADING" "$_MK_POSTFLIGHT_INFO_MODULE_COLOR"
  postflight::_module_group postflight_instructions \
    "$_MK_POSTFLIGHT_INSTRUCTIONS_HEADING" "$_MK_POSTFLIGHT_INSTRUCTIONS_MODULE_COLOR"
  postflight::_print_exec_hint
}

# The framework's own facts about this apply — independent of any module: which
# machine type ran, how many modules were active, and how many home files synced
# (home::sync records the count in context, in both dry-run and real mode).
postflight::_print_baseline() {
  local machine_type module_count files_synced
  machine_type="$(context::get "machine_type" --default "(none)")"
  module_count="$(context::get_array "modules.active" | grep -c '.' || true)"
  files_synced="$(context::get "home.files_synced" --default 0)"

  logging::step "Summary"
  logging::info "  machine type:       $machine_type"
  logging::info "  modules active:     $module_count"
  # "synced" would misdescribe a dry run, where the count is what *would* sync.
  if input::is_dry_run; then
    logging::info "  home files to sync: $files_synced"
  else
    logging::info "  home files synced:  $files_synced"
  fi
}

# postflight::_module_group HOOK HEADING MODULE_COLOR — walk the active modules
# in order, running <module>::HOOK on each that defines it. A module emits plain
# fact lines; this owns the presentation: the group heading (once, and only if
# some module emits), a per-module header in MODULE_COLOR, then the facts
# indented beneath it. A module that defines no hook, or emits nothing, is skipped.
postflight::_module_group() {
  local hook="$1" heading="$2" module_color="$3"
  local module facts line heading_printed=0
  while IFS= read -r module; do
    declare -F "${module}::${hook}" > /dev/null 2>&1 || continue
    facts="$("${module}::${hook}")"
    [ -n "$facts" ] || continue
    if [ "$heading_printed" -eq 0 ]; then
      logging::step "$heading"
      heading_printed=1
    fi
    logging::info "${module_color}${module}${MK_COLOR_RESET}"
    while IFS= read -r line; do
      logging::info "  $line"
    done <<< "$facts"
  done < <(context::get_array "modules.active")
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
