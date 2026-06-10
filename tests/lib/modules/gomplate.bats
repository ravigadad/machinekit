#!/usr/bin/env bats
# Tests for lib/modules/gomplate.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/gomplate.sh
  source "$MACHINEKIT_DIR/lib/modules/gomplate.sh"
}

teardown() {
  # Direct-call tests leave the memoized context file in a module global; bats
  # discards subshell-created ones with BATS_TEST_TMPDIR, but clean the rest.
  [ -n "${_MK_GOMPLATE_CTX_FILE:-}" ] && rm -f -- "$_MK_GOMPLATE_CTX_FILE"
  return 0
}

# --- gomplate::file_transforms ---

@test "file_transforms maps .tmpl to the render content handler" {
  run gomplate::file_transforms
  [ "$status" -eq 0 ]
  [ "$output" = "tmpl content gomplate::render" ]
}

# --- gomplate::install ---

@test "install installs gomplate, overriding dry-run so templates can render" {
  mktest::stub_function brew::install_formula gomplate --override-dry-run
  gomplate::install
  mktest::assert_stub_called brew::install_formula gomplate --override-dry-run
}

# --- gomplate::render ---

@test "render feeds the input through gomplate with a json context and returns its output" {
  _MK_GOMPLATE_CTX_FILE="the-context-file"
  mktest::stub_function gomplate::_ensure_context
  STUB_OUTPUT="rendered content" mktest::stub_function gomplate --context ".=file://the-context-file?type=application/json" -f "/staging/dot_foo.tmpl"
  run gomplate::render "/staging/dot_foo.tmpl"
  [ "$status" -eq 0 ]
  [ "$output" = "rendered content" ]
  mktest::assert_stub_called_in_order gomplate::_ensure_context
  mktest::assert_stub_called_in_order gomplate
}

# --- gomplate::_ensure_context ---

@test "_ensure_context instantiates _MK_GOMPLATE_CTX_FILE with context::json contents" {
  _MK_GOMPLATE_CTX_FILE=""
  STUB_OUTPUT="bunch-of-json" mktest::stub_function context::json
  mktest::stub_function lifecycle::register_cleanup
  gomplate::_ensure_context
  mktest::assert_stub_called lifecycle::register_cleanup gomplate::_cleanup_context
  [ "$(cat "$_MK_GOMPLATE_CTX_FILE")" = "bunch-of-json" ]
}

@test "_ensure_context does nothing if _MK_GOMPLATE_CTX_FILE is already set" {
  _MK_GOMPLATE_CTX_FILE="already-set"
  mktest::stub_function context::json
  gomplate::_ensure_context
  mktest::assert_stub_not_called context::json
}

# --- gomplate::_cleanup_context ---

@test "_cleanup_context removes the context file and resets the marker" {
  _MK_GOMPLATE_CTX_FILE=$(mktemp)
  local ctx="$_MK_GOMPLATE_CTX_FILE"
  [ -f "$ctx" ]
  gomplate::_cleanup_context
  [ ! -f "$ctx" ]
  [ -z "$_MK_GOMPLATE_CTX_FILE" ]
}
