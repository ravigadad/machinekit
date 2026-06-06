#!/usr/bin/env bats
# Tests for lib/modules/git.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/git.sh
  source "$MACHINEKIT_DIR/lib/modules/git.sh"
  mktest::stub_function logging::info
}

# --- git::preflight ---

@test "preflight resolves user name and email from config" {
  STUB_OUTPUT="Jane Doe"         mktest::stub_function config::get "module.git.user_name"  "--required" "--prompt" "Git user.name"
  STUB_OUTPUT="jane@example.com" mktest::stub_function config::get "module.git.user_email" "--required" "--prompt" "Git user.email"
  git::preflight
  mktest::assert_stub_called config::get "module.git.user_name"  "--required" "--prompt" "Git user.name"
  mktest::assert_stub_called config::get "module.git.user_email" "--required" "--prompt" "Git user.email"
}

@test "preflight fails when user name cannot be resolved" {
  STUB_EXIT=1 mktest::stub_function config::get "module.git.user_name" "--required" "--prompt" "Git user.name"
  run ! git::preflight
}

@test "preflight fails when user email cannot be resolved" {
  STUB_OUTPUT="Jane Doe" mktest::stub_function config::get "module.git.user_name"  "--required" "--prompt" "Git user.name"
  STUB_EXIT=1            mktest::stub_function config::get "module.git.user_email" "--required" "--prompt" "Git user.email"
  run ! git::preflight
}

# --- git::install ---

@test "install is a no-op" {
  git::install
}
