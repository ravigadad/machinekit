#!/usr/bin/env bats
# Tests for lib/modules/git.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/git.sh
  source "$MACHINEKIT_DIR/lib/modules/git.sh"
  mktest::stub_function logging::info
}

# --- git::preflight ---

@test "preflight resolves user name and email from context" {
  STUB_OUTPUT="Jane Doe"         mktest::stub_function context::get "git.user_name"  "--required"
  STUB_OUTPUT="jane@example.com" mktest::stub_function context::get "git.user_email" "--required"
  git::preflight
  mktest::assert_stub_called context::get "git.user_name"  "--required"
  mktest::assert_stub_called context::get "git.user_email" "--required"
}

@test "preflight fails when user name cannot be resolved" {
  STUB_EXIT=1 mktest::stub_function context::get "git.user_name" "--required"
  run ! git::preflight
}

@test "preflight fails when user email cannot be resolved" {
  STUB_OUTPUT="Jane Doe" mktest::stub_function context::get "git.user_name"  "--required"
  STUB_EXIT=1            mktest::stub_function context::get "git.user_email" "--required"
  run ! git::preflight
}

# --- git::install ---

@test "install is a no-op" {
  git::install
}
