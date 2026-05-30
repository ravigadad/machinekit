#!/usr/bin/env bash
# Hook execution.
#
# Hooks are shell scripts the user drops into blueprint hooks/<phase>/
# directories to extend the apply pipeline. They run in alphabetical order
# within their phase. Each runs in a fresh bash subprocess so a hook's
# `exit` or `set -e` failure can't tear down the apply pipeline silently —
# but a non-zero exit will fail the apply (intentional: hooks that error
# should fail loudly).

hooks::run_post_apply() {
  logging::step "post-apply hooks"
  local hook_dir
  hook_dir="$(blueprints::dir)/common/hooks/post-apply"
  if [ ! -d "$hook_dir" ]; then
    logging::info "No common/hooks/post-apply directory; skipping."
    return 0
  fi
  hooks::_execute_hooks "$hook_dir"
}

hooks::_execute_hooks() {
  local hook_dir="$1"
  local hook dry_run=false
  if input::is_dry_run; then dry_run=true; fi
  if [ "$dry_run" = false ]; then
    export MACHINEKIT_DIR
    export MACHINEKIT_SUPPORT="$MACHINEKIT_DIR/lib/machinekit/hook-support.sh"
  fi
  for hook in "$hook_dir"/*.sh; do
    [ -f "$hook" ] || continue
    hooks::_execute_hook "$hook" "$dry_run"
  done
  [ "$dry_run" = true ] || logging::success "Hooks complete."
}

hooks::_execute_hook() {
  local hook="$1" dry_run="$2"
  if [ "$dry_run" = true ]; then
    logging::dry_run "would run hook: $(basename "$hook")"
  else
    logging::info "Running hook: $(basename "$hook")"
    bash "$hook" || return 1
  fi
}
