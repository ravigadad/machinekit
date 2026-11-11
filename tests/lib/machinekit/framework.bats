#!/usr/bin/env bats
# Tests for lib/machinekit/framework.sh — moving machinekit's own clone to its
# update target. The functions that read git state run against throwaway repos
# under $BATS_TEST_TMPDIR; the orchestrators stub them.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/framework.sh
  source "$MACHINEKIT_DIR/lib/machinekit/framework.sh"
  # A home of its own, so the real git config (signing, hooks) never applies.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="fake-author" GIT_AUTHOR_EMAIL="fake@example.invalid"
  export GIT_COMMITTER_NAME="fake-author" GIT_COMMITTER_EMAIL="fake@example.invalid"
}

# An origin with one commit on main, and a clone of it as the framework dir.
_mk_test_origin_and_clone() {
  origin_dir="$BATS_TEST_TMPDIR/origin"
  git init -q -b main "$origin_dir"
  _mk_test_commit "$origin_dir" "first"
  git clone -q "$origin_dir" "$BATS_TEST_TMPDIR/clone"
  MACHINEKIT_DIR="$BATS_TEST_TMPDIR/clone"
}

_mk_test_commit() {
  local repo_dir="$1" message="$2"
  printf '%s\n' "$message" > "$repo_dir/file.txt"
  git -C "$repo_dir" add file.txt
  git -C "$repo_dir" commit -q -m "$message"
}

# --- framework::update ---

@test "update fetches, then moves the clone to the target of the configured track" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_OUTPUT="" mktest::stub_function framework::local_changes
  mktest::stub_function framework::move_to "fake-target" 0
  mktest::stub_function logging::success
  framework::update 0
  mktest::assert_stub_called_in_order framework::fetch
  mktest::assert_stub_called_in_order framework::move_to "fake-target" 0
}

@test "update refuses, naming what is in the way, when the clone has local changes" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_OUTPUT="fake-change" mktest::stub_function framework::local_changes
  mktest::stub_function framework::move_to
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run framework::update 0
  [ "$status" -eq 1 ]
  MATCH="fake-change" mktest::assert_stub_called lifecycle::fail
  MATCH="--reset" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called framework::move_to
}

@test "update with reset moves past local changes without looking at them" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  mktest::stub_function framework::local_changes
  mktest::stub_function framework::move_to "fake-target" 1
  mktest::stub_function logging::success
  framework::update 1
  mktest::assert_stub_called framework::move_to "fake-target" 1
  mktest::assert_stub_not_called framework::local_changes
}

@test "update stops when the fetch fails" {
  STUB_RETURN=1 mktest::stub_function framework::fetch
  mktest::stub_function framework::move_to
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run framework::update 0
  [ "$status" -eq 1 ]
  MATCH="fetch" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called framework::move_to
}

@test "update stops when reading the track fails" {
  mktest::stub_function framework::fetch
  STUB_EXIT=97 mktest::stub_function framework::track
  run framework::update 0
  [ "$status" -eq 97 ]
}

@test "update stops when resolving the target fails" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_EXIT=97 mktest::stub_function framework::target "fake-track"
  run framework::update 0
  [ "$status" -eq 97 ]
}

# --- framework::check_for_update ---

@test "check_for_update warns how far behind the target the clone is, and carries on" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_RETURN=1 mktest::stub_function framework::is_on "fake-target"
  STUB_OUTPUT="false" mktest::stub_function context::get "auto_update" --default false --coerce boolean
  STUB_OUTPUT="3" mktest::stub_function framework::commits_until "fake-target"
  mktest::stub_function logging::warn
  framework::check_for_update
  MATCH="3 commits behind fake-target.*machinekit update" mktest::assert_stub_called logging::warn
}

@test "check_for_update says the clone is off its target when it is not behind it" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_RETURN=1 mktest::stub_function framework::is_on "fake-target"
  STUB_OUTPUT="false" mktest::stub_function context::get "auto_update" --default false --coerce boolean
  STUB_OUTPUT="0" mktest::stub_function framework::commits_until "fake-target"
  mktest::stub_function logging::warn
  framework::check_for_update
  MATCH="not on fake-target.*machinekit update" mktest::assert_stub_called logging::warn
}

@test "check_for_update is silent when the clone is on its target" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  mktest::stub_function framework::is_on "fake-target"
  mktest::stub_function logging::warn
  framework::check_for_update
  mktest::assert_stub_not_called logging::warn
}

@test "check_for_update warns and carries on when the fetch fails" {
  STUB_RETURN=1 mktest::stub_function framework::fetch
  mktest::stub_function framework::track
  mktest::stub_function logging::warn
  framework::check_for_update
  MATCH="could not check" mktest::assert_stub_called logging::warn
  mktest::assert_stub_not_called framework::track
}

@test "check_for_update does nothing in the apply that an auto-update started" {
  export _MK_FRAMEWORK_UPDATED=1
  mktest::stub_function framework::fetch
  framework::check_for_update
  mktest::assert_stub_not_called framework::fetch
}

@test "check_for_update updates and reruns the apply when auto_update is on" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_RETURN=1 mktest::stub_function framework::is_on "fake-target"
  STUB_OUTPUT="true" mktest::stub_function context::get "auto_update" --default false --coerce boolean
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function framework::_update_and_rerun_apply
  mktest::stub_function logging::warn
  framework::check_for_update
  mktest::assert_stub_called framework::_update_and_rerun_apply
  mktest::assert_stub_not_called logging::warn
}

@test "check_for_update only warns on a dry run, even when auto_update is on" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_RETURN=1 mktest::stub_function framework::is_on "fake-target"
  STUB_OUTPUT="true" mktest::stub_function context::get "auto_update" --default false --coerce boolean
  mktest::stub_function input::is_dry_run
  STUB_OUTPUT="3" mktest::stub_function framework::commits_until "fake-target"
  mktest::stub_function framework::_update_and_rerun_apply
  mktest::stub_function logging::warn
  framework::check_for_update
  mktest::assert_stub_not_called framework::_update_and_rerun_apply
  MATCH="3 commits behind" mktest::assert_stub_called logging::warn
}

@test "check_for_update stops when reading the track fails" {
  mktest::stub_function framework::fetch
  STUB_EXIT=97 mktest::stub_function framework::track
  run framework::check_for_update
  [ "$status" -eq 97 ]
}

@test "check_for_update stops when reading auto_update fails" {
  mktest::stub_function framework::fetch
  STUB_OUTPUT="fake-track" mktest::stub_function framework::track
  STUB_OUTPUT="fake-target" mktest::stub_function framework::target "fake-track"
  STUB_RETURN=1 mktest::stub_function framework::is_on "fake-target"
  STUB_EXIT=97 mktest::stub_function context::get "auto_update" --default false --coerce boolean
  run framework::check_for_update
  [ "$status" -eq 97 ]
}

# --- framework::_update_and_rerun_apply ---

@test "_update_and_rerun_apply releases the lock, updates, then reruns apply marked as updated" {
  mktest::stub_function logging::step
  mktest::stub_function lifecycle::release_lock
  mktest::stub_function framework::_run_update_command
  mktest::stub_function lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 "$MACHINEKIT_DIR/bin/machinekit" apply
  framework::_update_and_rerun_apply
  mktest::assert_stub_called_in_order lifecycle::release_lock
  mktest::assert_stub_called_in_order framework::_run_update_command
  mktest::assert_stub_called_in_order lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 "$MACHINEKIT_DIR/bin/machinekit" apply
}

@test "_update_and_rerun_apply stops the apply when the update fails" {
  mktest::stub_function logging::step
  mktest::stub_function lifecycle::release_lock
  STUB_RETURN=1 mktest::stub_function framework::_run_update_command
  mktest::stub_function lifecycle::exec
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run framework::_update_and_rerun_apply
  [ "$status" -eq 1 ]
  mktest::assert_stub_not_called lifecycle::exec
}

# --- framework::track ---

@test "track reads update.track, defaulting to release" {
  STUB_OUTPUT="main" mktest::stub_function context::get "update.track" --default release
  run framework::track
  [ "$output" = "main" ]
}

@test "track rejects a value other than release or main" {
  STUB_OUTPUT="nightly" mktest::stub_function context::get "update.track" --default release
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run framework::track
  [ "$status" -eq 1 ]
  MATCH="nightly" mktest::assert_stub_called lifecycle::fail
}

@test "track stops when reading update.track fails" {
  STUB_EXIT=97 mktest::stub_function context::get "update.track" --default release
  run framework::track
  [ "$status" -eq 97 ]
}

# --- framework::target ---

@test "target for main is the tip of origin/main" {
  run framework::target main
  [ "$output" = "origin/main" ]
}

@test "target for release is the highest release tag by version, ignoring other tags" {
  _mk_test_origin_and_clone
  git -C "$MACHINEKIT_DIR" tag 0.9.0
  git -C "$MACHINEKIT_DIR" tag 0.10.0
  git -C "$MACHINEKIT_DIR" tag 0.11.0-rc1
  git -C "$MACHINEKIT_DIR" tag v9.9.9
  run framework::target release
  [ "$output" = "0.10.0" ]
}

# --- framework::fetch ---

@test "fetch brings in origin's new commits and tags" {
  _mk_test_origin_and_clone
  _mk_test_commit "$origin_dir" "second"
  git -C "$origin_dir" tag 0.2.0
  framework::fetch
  [ "$(git -C "$MACHINEKIT_DIR" rev-parse 0.2.0)" = "$(git -C "$origin_dir" rev-parse HEAD)" ]
  [ "$(git -C "$MACHINEKIT_DIR" rev-parse origin/main)" = "$(git -C "$origin_dir" rev-parse HEAD)" ]
}

@test "fetch fails when origin cannot be reached" {
  _mk_test_origin_and_clone
  rm -rf "$origin_dir"
  run ! framework::fetch
}

# --- framework::local_changes ---

@test "local_changes is empty for a clean clone, even with untracked files" {
  _mk_test_origin_and_clone
  printf 'scratch\n' > "$MACHINEKIT_DIR/untracked.txt"
  run framework::local_changes
  [ -z "$output" ]
}

@test "local_changes lists a modified tracked file" {
  _mk_test_origin_and_clone
  printf 'edited\n' > "$MACHINEKIT_DIR/file.txt"
  run framework::local_changes
  [[ "$output" == *"file.txt"* ]]
}

@test "local_changes lists a commit that origin does not have" {
  _mk_test_origin_and_clone
  _mk_test_commit "$MACHINEKIT_DIR" "fake-local-commit"
  run framework::local_changes
  [[ "$output" == *"fake-local-commit"* ]]
}

# --- framework::move_to ---

@test "move_to checks the target out, detached" {
  _mk_test_origin_and_clone
  git -C "$MACHINEKIT_DIR" tag 0.1.0
  _mk_test_commit "$origin_dir" "second"
  git -C "$MACHINEKIT_DIR" fetch -q origin
  framework::move_to origin/main 0
  [ "$(git -C "$MACHINEKIT_DIR" rev-parse HEAD)" = "$(git -C "$origin_dir" rev-parse HEAD)" ]
  run git -C "$MACHINEKIT_DIR" symbolic-ref -q HEAD
  [ "$status" -ne 0 ]
}

@test "move_to without force leaves local changes in place and fails when they conflict" {
  _mk_test_origin_and_clone
  _mk_test_commit "$origin_dir" "second"
  git -C "$MACHINEKIT_DIR" fetch -q origin
  printf 'edited\n' > "$MACHINEKIT_DIR/file.txt"
  run ! framework::move_to origin/main 0
  [ "$(cat "$MACHINEKIT_DIR/file.txt")" = "edited" ]
}

@test "move_to with force discards local changes to tracked files" {
  _mk_test_origin_and_clone
  _mk_test_commit "$origin_dir" "second"
  git -C "$MACHINEKIT_DIR" fetch -q origin
  printf 'edited\n' > "$MACHINEKIT_DIR/file.txt"
  framework::move_to origin/main 1
  [ "$(cat "$MACHINEKIT_DIR/file.txt")" = "second" ]
}

# --- framework::is_on / framework::commits_until ---

@test "is_on is true only when HEAD is the target's commit" {
  _mk_test_origin_and_clone
  git -C "$MACHINEKIT_DIR" tag 0.1.0
  framework::is_on 0.1.0
  _mk_test_commit "$origin_dir" "second"
  git -C "$MACHINEKIT_DIR" fetch -q origin
  run ! framework::is_on origin/main
}

@test "commits_until counts the target's commits that HEAD lacks" {
  _mk_test_origin_and_clone
  _mk_test_commit "$origin_dir" "second"
  _mk_test_commit "$origin_dir" "third"
  git -C "$MACHINEKIT_DIR" fetch -q origin
  run framework::commits_until origin/main
  [ "$output" = "2" ]
}

# --- framework::_run_update_command ---

@test "_run_update_command runs this clone's update command and passes on its status" {
  MACHINEKIT_DIR="$BATS_TEST_TMPDIR/framework"
  mkdir -p "$MACHINEKIT_DIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\nexit 3\n' "$BATS_TEST_TMPDIR" > "$MACHINEKIT_DIR/bin/machinekit"
  chmod +x "$MACHINEKIT_DIR/bin/machinekit"
  run framework::_run_update_command
  [ "$status" -eq 3 ]
  [ "$(cat "$BATS_TEST_TMPDIR/args")" = "update" ]
}
