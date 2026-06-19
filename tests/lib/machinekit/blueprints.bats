#!/usr/bin/env bats
# Tests for lib/machinekit/blueprints.sh — blueprint-specific orchestration only.
# The source-agnostic fetch machinery it delegates to (fetch::resolve_protocol,
# fetch::into) is stubbed here at the seam and tested for real in fetch.bats.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  unset _MK_BLUEPRINTS_LOADED
  # shellcheck source=../../../lib/machinekit/blueprints.sh
  source "$MACHINEKIT_DIR/lib/machinekit/blueprints.sh"
  _MK_BLUEPRINTS_DIR=""
  mktest::stub_function logging::step
  mktest::stub_function logging::info
}

# --- blueprints::fetch (orchestrator) ---

@test "fetch resolves the protocol, caches a sniffed value, prepares dest, and delegates" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/tmp-dest"
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  STUB_OUTPUT="git" mktest::stub_function fetch::resolve_protocol "https://github.com/user/bp" ""
  mktest::stub_function context::set "blueprints.source_protocol" "git"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function fetch::into "https://github.com/user/bp" "$BATS_TEST_TMPDIR/tmp-dest" "git"
  mktest::stub_function input::is_dry_run
  blueprints::fetch
  mktest::assert_stub_called context::set "blueprints.source_protocol" "git"
  mktest::assert_stub_called_in_order blueprints::_prepare_dest
  mktest::assert_stub_called_in_order fetch::into "https://github.com/user/bp" "$BATS_TEST_TMPDIR/tmp-dest" "git"
}

@test "fetch honors an explicit protocol override and does not cache it" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/tmp-dest"
  STUB_OUTPUT="/local/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_OUTPUT="cp" mktest::stub_function context::get "blueprints.source_protocol"
  STUB_OUTPUT="cp" mktest::stub_function fetch::resolve_protocol "/local/bp" "cp"
  mktest::stub_function context::set
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function fetch::into "/local/bp" "$BATS_TEST_TMPDIR/tmp-dest" "cp"
  mktest::stub_function input::is_dry_run
  blueprints::fetch
  mktest::assert_stub_called fetch::into "/local/bp" "$BATS_TEST_TMPDIR/tmp-dest" "cp"
  mktest::assert_stub_not_called context::set
}

@test "fetch in non-dry-run moves the temp dir to the permanent location and updates _MK_BLUEPRINTS_DIR" {
  local tmp_dir="$BATS_TEST_TMPDIR/tmp-fetch"
  mkdir "$tmp_dir"
  _MK_BLUEPRINTS_DIR="$tmp_dir"
  local final="$BATS_TEST_TMPDIR/final-bp"
  export MACHINEKIT_BLUEPRINTS_DIR="$final"
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  STUB_OUTPUT="git" mktest::stub_function fetch::resolve_protocol "https://github.com/user/bp" ""
  mktest::stub_function context::set "blueprints.source_protocol" "git"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function fetch::into
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  blueprints::fetch
  [ ! -d "$tmp_dir" ]
  [ -d "$final" ]
  [ "$_MK_BLUEPRINTS_DIR" = "$final" ]
}

@test "fetch in non-dry-run creates parent dirs when they do not exist" {
  local tmp_dir="$BATS_TEST_TMPDIR/tmp-fetch"
  mkdir "$tmp_dir"
  _MK_BLUEPRINTS_DIR="$tmp_dir"
  local final="$BATS_TEST_TMPDIR/nonexistent/parent/blueprints"
  export MACHINEKIT_BLUEPRINTS_DIR="$final"
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  STUB_OUTPUT="git" mktest::stub_function fetch::resolve_protocol "https://github.com/user/bp" ""
  mktest::stub_function context::set "blueprints.source_protocol" "git"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function fetch::into
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  blueprints::fetch
  [ -d "$final" ]
  [ "$_MK_BLUEPRINTS_DIR" = "$final" ]
}

# --- blueprints::dir ---

@test "dir fails before fetch has been called" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::dir
  MATCH="before.*fetch" mktest::assert_stub_called lifecycle::fail
}

@test "dir returns the set value after _MK_BLUEPRINTS_DIR is assigned" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/bp"
  result=$(blueprints::dir)
  [ "$result" = "$BATS_TEST_TMPDIR/bp" ]
}

# --- blueprints::_prepare_dest ---

@test "_prepare_dest sets _MK_BLUEPRINTS_DIR to a temp path, removes it, and registers cleanup" {
  local fake_dir="$BATS_TEST_TMPDIR/fake-tmp-dir"
  mkdir "$fake_dir"
  STUB_OUTPUT="$fake_dir" mktest::stub_function mktemp "-d"
  mktest::stub_function lifecycle::register_cleanup "blueprints::cleanup_dest"
  blueprints::_prepare_dest
  [ "$_MK_BLUEPRINTS_DIR" = "$fake_dir" ]
  [ ! -e "$_MK_BLUEPRINTS_DIR" ]
  mktest::assert_stub_called lifecycle::register_cleanup "blueprints::cleanup_dest"
}

# --- blueprints::cleanup_dest ---

@test "cleanup_dest does nothing when _MK_BLUEPRINTS_DIR is empty" {
  _MK_BLUEPRINTS_DIR=""
  blueprints::cleanup_dest
}

@test "cleanup_dest removes the directory and clears _MK_BLUEPRINTS_DIR" {
  local dir="$BATS_TEST_TMPDIR/to-clean"
  mkdir "$dir"
  _MK_BLUEPRINTS_DIR="$dir"
  blueprints::cleanup_dest
  [ ! -e "$dir" ]
  [ -z "$_MK_BLUEPRINTS_DIR" ]
}
