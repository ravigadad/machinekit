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
  local blueprints_dir common_dir
  blueprints_dir="$(blueprints::dir)"
  common_dir="$blueprints_dir/common/hooks/post-apply"
  local found=false

  if [ -d "$common_dir" ]; then
    found=true
    hooks::_execute_hooks "$common_dir"
  fi

  local machine_type
  machine_type="$(context::get "machine_type" 2>/dev/null || true)"
  if [ -n "$machine_type" ]; then
    local mt_dir="$blueprints_dir/machine_types/$machine_type/hooks/post-apply"
    if [ -d "$mt_dir" ]; then
      found=true
      hooks::_execute_hooks "$mt_dir"
    fi
  fi

  if [ "$found" = false ]; then
    logging::info "No post-apply hooks; skipping."
    return 0
  fi
  input::is_dry_run || logging::success "Hooks complete."
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
