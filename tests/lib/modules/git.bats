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

@test "preflight stops when resolving the user name fails" {
  STUB_EXIT=97 mktest::stub_function config::get "module.git.user_name" "--required" "--prompt" "Git user.name"
  mktest::stub_function config::get "module.git.user_email" "--required" "--prompt" "Git user.email"
  mktest::stub_function logging::info
  run git::preflight
  [ "$status" -eq 97 ]
}

@test "preflight stops when resolving the user email fails" {
  STUB_OUTPUT="Jane Doe" mktest::stub_function config::get "module.git.user_name"  "--required" "--prompt" "Git user.name"
  STUB_EXIT=97           mktest::stub_function config::get "module.git.user_email" "--required" "--prompt" "Git user.email"
  mktest::stub_function logging::info
  run git::preflight
  [ "$status" -eq 97 ]
}

# --- git::install ---

@test "install is a no-op" {
  git::install
}
