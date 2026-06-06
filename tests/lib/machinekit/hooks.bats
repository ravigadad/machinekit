#!/usr/bin/env bats
# Tests for lib/machinekit/hooks.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/hooks.sh
  source "$MACHINEKIT_DIR/lib/machinekit/hooks.sh"

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  STUB_OUTPUT="$BATS_TEST_TMPDIR/blueprints" mktest::stub_function blueprints::dir
}

_hooks_dir() { printf '%s\n' "$BATS_TEST_TMPDIR/blueprints/common/hooks/post-apply"; }
_mt_hooks_dir() { printf '%s\n' "$BATS_TEST_TMPDIR/blueprints/machine_types/laptop/hooks/post-apply"; }

# --- hooks::run_post_apply ---

@test "run_post_apply skips when no hook dirs exist" {
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function hooks::_execute_hooks
  run hooks::run_post_apply
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called hooks::_execute_hooks
}

@test "run_post_apply delegates to _execute_hooks when common hooks dir exists" {
  mkdir -p "$(_hooks_dir)"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  mktest::assert_stub_called hooks::_execute_hooks "$(_hooks_dir)"
}

@test "run_post_apply logs success after common hooks run and not dry-run" {
  mkdir -p "$(_hooks_dir)"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  mktest::assert_stub_called logging::success
}

@test "run_post_apply does not log success in dry-run" {
  mkdir -p "$(_hooks_dir)"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  mktest::assert_stub_not_called logging::success
}

@test "run_post_apply executes machine_type hooks when machine_type is set and dir exists" {
  mkdir -p "$(_mt_hooks_dir)"
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  mktest::assert_stub_called hooks::_execute_hooks "$(_mt_hooks_dir)"
}

@test "run_post_apply executes both common and machine_type hooks when both dirs exist" {
  mkdir -p "$(_hooks_dir)" "$(_mt_hooks_dir)"
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  TIMES=2 mktest::assert_stub_called hooks::_execute_hooks
  mktest::assert_stub_called hooks::_execute_hooks "$(_hooks_dir)"
  mktest::assert_stub_called hooks::_execute_hooks "$(_mt_hooks_dir)"
}

@test "run_post_apply skips machine_type hooks when machine_type is not set" {
  mkdir -p "$(_hooks_dir)"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  TIMES=1 mktest::assert_stub_called hooks::_execute_hooks
  mktest::assert_stub_called hooks::_execute_hooks "$(_hooks_dir)"
}

@test "run_post_apply skips machine_type hooks when machine_type dir does not exist" {
  mkdir -p "$(_hooks_dir)"
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hooks
  hooks::run_post_apply
  TIMES=1 mktest::assert_stub_called hooks::_execute_hooks
  mktest::assert_stub_called hooks::_execute_hooks "$(_hooks_dir)"
}

# --- hooks::_execute_hooks ---

@test "_execute_hooks succeeds with no .sh files in the directory" {
  local hdir
  hdir="$(_hooks_dir)"
  mkdir -p "$hdir"
  touch "$hdir/README.md"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  run hooks::_execute_hooks "$hdir"
  [ "$status" -eq 0 ]
}

@test "_execute_hooks calls _execute_hook for each .sh file and skips non-.sh files" {
  local hdir
  hdir="$(_hooks_dir)"
  mkdir -p "$hdir"
  touch "$hdir/10-first.sh" "$hdir/20-second.sh" "$hdir/README.md"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hook
  hooks::_execute_hooks "$hdir"
  TIMES=2 mktest::assert_stub_called hooks::_execute_hook
  MATCH="10-first\.sh" mktest::assert_stub_called hooks::_execute_hook
  MATCH="20-second\.sh" mktest::assert_stub_called hooks::_execute_hook
}

@test "_execute_hooks in dry-run passes dry_run=true to _execute_hook and does not log success" {
  local hdir
  hdir="$(_hooks_dir)"
  mkdir -p "$hdir"
  touch "$hdir/hook.sh"
  mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hook
  hooks::_execute_hooks "$hdir"
  MATCH="^true$" mktest::assert_stub_called hooks::_execute_hook
  mktest::assert_stub_not_called logging::success
}

@test "_execute_hooks not in dry-run passes dry_run=false to _execute_hook" {
  local hdir
  hdir="$(_hooks_dir)"
  mkdir -p "$hdir"
  touch "$hdir/hook.sh"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hooks::_execute_hook
  hooks::_execute_hooks "$hdir"
  MATCH="^false$" mktest::assert_stub_called hooks::_execute_hook
  mktest::assert_stub_not_called logging::success
}

@test "_execute_hooks exports MACHINEKIT_SUPPORT so hooks can source it" {
  local hdir support_file
  hdir="$(_hooks_dir)"
  support_file="$BATS_TEST_TMPDIR/support_path.txt"
  mkdir -p "$hdir"
  cat > "$hdir/check.sh" <<HOOKSCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$MACHINEKIT_SUPPORT" > "$support_file"
HOOKSCRIPT
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  run hooks::_execute_hooks "$hdir"
  [ "$status" -eq 0 ]
  [ "$(cat "$support_file")" = "$MACHINEKIT_DIR/lib/machinekit/hook-support.sh" ]
}

# --- hooks::_execute_hook ---

@test "_execute_hook in dry-run logs the hook basename and does not run the script" {
  local hook trace
  hook="$BATS_TEST_TMPDIR/my-hook.sh"
  trace="$BATS_TEST_TMPDIR/ran"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$trace" > "$hook"
  mktest::stub_function logging::dry_run
  hooks::_execute_hook "$hook" "true"
  MATCH="my-hook\.sh" mktest::assert_stub_called logging::dry_run
  [ ! -f "$trace" ]
}

@test "_execute_hook not in dry-run runs the script and logs the hook name" {
  local hook trace
  hook="$BATS_TEST_TMPDIR/my-hook.sh"
  trace="$BATS_TEST_TMPDIR/ran"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$trace" > "$hook"
  hooks::_execute_hook "$hook" "false"
  [ -f "$trace" ]
  MATCH="my-hook\.sh" mktest::assert_stub_called logging::info
}

@test "_execute_hook not in dry-run propagates non-zero exit from hook" {
  local hook
  hook="$BATS_TEST_TMPDIR/fail.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$hook"
  run hooks::_execute_hook "$hook" "false"
  [ "$status" -ne 0 ]
}
