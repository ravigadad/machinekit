#!/usr/bin/env bats
# Tests for lib/machinekit/logging.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/logging.sh
  source "$MACHINEKIT_DIR/lib/machinekit/logging.sh"
}

# --- logging::_init_colors ---

@test "_init_colors sets color variables when NO_COLOR is unset and stderr is a tty" {
  # Redirect stderr to a real tty if available; otherwise skip when no tty is present.
  local tty
  tty=$(tty 2>/dev/null) || skip "no controlling tty in this environment"
  NO_COLOR="" logging::_init_colors 2>"$tty"
  [ -n "$MK_COLOR_RED" ]
  [ -n "$MK_COLOR_YELLOW" ]
  [ -n "$MK_COLOR_GREEN" ]
  [ -n "$MK_COLOR_BLUE" ]
  [ -n "$MK_COLOR_BOLD" ]
  [ -n "$MK_COLOR_RESET" ]
}

@test "_init_colors clears color variables when NO_COLOR is set" {
  NO_COLOR=1 logging::_init_colors
  [ -z "$MK_COLOR_RED" ]
  [ -z "$MK_COLOR_YELLOW" ]
  [ -z "$MK_COLOR_GREEN" ]
  [ -z "$MK_COLOR_BLUE" ]
  [ -z "$MK_COLOR_BOLD" ]
  [ -z "$MK_COLOR_RESET" ]
}

@test "sourcing the file a second time is a no-op" {
  # Verify the idempotency guard: a second source must not redefine or reset anything.
  logging::info() { echo "original"; }
  source "$MACHINEKIT_DIR/lib/machinekit/logging.sh"
  [ "$(logging::info)" = "original" ]
}

# --- logging::_emit ---

@test "_emit writes '[machinekit] prefix message' to stderr" {
  MK_COLOR_RESET=""
  run --separate-stderr logging::_emit "the-color" "tag:" "the message"
  [[ "$stderr" == *"the-color"*"[machinekit] tag: the message"* ]]
}

@test "_emit handles no prefix gracefully" {
  MK_COLOR_RESET=""
  run --separate-stderr logging::_emit "the-color" "" "the message"
  [[ "$stderr" == *"the-color"*"[machinekit] the message"* ]]
}

# --- logging::_emit wrappers for levels ---

_assert_level_calls_emit_with_prefix() {
  local level="$1" prefix="$2"

  STUB_OUTPUT="the-color" mktest::stub_function logging::_color_for_level "$level"
  mktest::stub_function logging::_emit "the-color" "$prefix" "the-message"
  "logging::${level}" "the-message"
  mktest::assert_stub_called logging::_emit "the-color" "$prefix" "the-message"
}

@test "info writes the message with [machinekit] prefix to stderr" {
  _assert_level_calls_emit_with_prefix info ""
}

@test "warn writes the message with warning: prefix to stderr" {
  _assert_level_calls_emit_with_prefix warn "warning:"
}

@test "error writes the message with error: prefix to stderr" {
  _assert_level_calls_emit_with_prefix error "error:"
}

@test "success writes the message with checkmark prefix to stderr" {
  _assert_level_calls_emit_with_prefix success "✓"
}

@test "dry-run writes the message with dry-run: prefix to stderr" {
  _assert_level_calls_emit_with_prefix dry_run "dry-run:"
}

@test "attention writes the message with [machinekit] prefix to stderr" {
  _assert_level_calls_emit_with_prefix attention ""
}

@test "debug is silent when MACHINEKIT_VERBOSE is unset" {
  unset MACHINEKIT_VERBOSE
  mktest::stub_function logging::_emit
  logging::debug "hidden"
  mktest::assert_stub_not_called logging::_emit
}

@test "debug is silent when MACHINEKIT_VERBOSE=0" {
  mktest::stub_function logging::_emit
  MACHINEKIT_VERBOSE=0 logging::debug "hidden"
  mktest::assert_stub_not_called logging::_emit
}

@test "debug writes the message with debug: tag when MACHINEKIT_VERBOSE=1" {
  MACHINEKIT_VERBOSE=1
  _assert_level_calls_emit_with_prefix debug "debug:"
}

# --- logging::fail ---

@test "fail delegates to error" {
  mktest::stub_function logging::error "fatal problem"
  logging::fail "fatal problem"
  mktest::assert_stub_called logging::error "fatal problem"
}

# --- logging::banner ---

@test "banner emits separator and all content lines with [machinekit] prefix" {
  STUB_OUTPUT="the-color" mktest::stub_function logging::_color_for_level the_level
  run --separate-stderr logging::banner the_level "$(printf 'line one\nline two')"
  [[ "$stderr" == *"the-color"*"[machinekit]"*"==="* ]]
  [[ "$stderr" == *"the-color"*"[machinekit]"*"line one"* ]]
  [[ "$stderr" == *"the-color"*"[machinekit]"*"line two"* ]]
}

# --- logging::dry_run ---

@test "dry_run output reaches stderr" {
  run --separate-stderr logging::dry_run "would install: git"
  [[ "$stderr" == *"dry-run:"*"would install: git"* ]]
}

@test "dry_run delegates to _emit with dry-run: prefix" {
  _assert_level_calls_emit_with_prefix dry_run "dry-run:"
}

# --- logging::step ---

@test "step emits the message in bold" {
  MK_COLOR_BOLD="make-it-bold:"
  mktest::stub_function logging::_emit "make-it-bold:" "" "make-it-bold:the-message"
  logging::step "the-message"
  mktest::assert_stub_called logging::_emit "make-it-bold:" "" "make-it-bold:the-message"
}

# --- logging::_color_for_level ---

_assert_color_for_level() {
  local level="$1" color="$2"
  printf -v "MK_COLOR_$color" 'placeholder'
  result=$(logging::_color_for_level "$level")
  [ "$result" = "placeholder" ]
}

@test "_color_for_level returns blue for debug" {
  _assert_color_for_level debug BLUE
}

@test "_color_for_level returns blue for info" {
  _assert_color_for_level info BLUE
}

@test "_color_for_level returns yellow for warn" {
  _assert_color_for_level warn YELLOW
}

@test "_color_for_level returns red for error" {
  _assert_color_for_level error RED
}

@test "_color_for_level returns green for success" {
  _assert_color_for_level success GREEN
}

@test "_color_for_level returns yellow for dry_run" {
  _assert_color_for_level dry_run YELLOW
}
