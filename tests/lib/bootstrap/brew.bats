#!/usr/bin/env bats
# Tests for lib/bootstrap/brew.sh — the bootstrap island's Homebrew orchestration,
# built on the shared lib/common/brew_core.sh primitives. Pure-3.2.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # Isolate from any ambient HOMEBREW_NO_ASK (CI sets it job-level); the interactive
  # test proves install_bash doesn't itself set it, which only holds against a clean env.
  unset HOMEBREW_NO_ASK
  # shellcheck source=../../../lib/bootstrap/brew.sh
  source "$MACHINEKIT_DIR/lib/bootstrap/brew.sh"
}

# --- bootstrap::brew::_have ---

@test "_have is true for a present command and false for an absent one" {
  bootstrap::brew::_have bash
  run ! bootstrap::brew::_have mk_definitely_absent_cmd_xyz
}

# --- bootstrap::brew::_require ---

@test "_require succeeds when the command is present" {
  mktest::stub_function bootstrap::brew::_have "git"
  bootstrap::brew::_require git "unused message"
}

@test "_require fails with the message when the command is absent" {
  STUB_RETURN=1 mktest::stub_function bootstrap::brew::_have "missingcmd"
  STUB_EXIT=1 mktest::stub_function bootstrap::brew::_fail
  run bootstrap::brew::_require missingcmd "the message"
  [ "$status" -ne 0 ]
  mktest::assert_stub_called bootstrap::brew::_fail
}

# --- bootstrap::brew::ensure ---

@test "ensure skips installation when brew is already present" {
  mktest::stub_function brew_core::setup_path
  mktest::stub_function bootstrap::brew::_have "brew"
  mktest::stub_function bootstrap::brew::_run_installer
  bootstrap::brew::ensure
  mktest::assert_stub_not_called bootstrap::brew::_run_installer
}

@test "ensure installs Homebrew when absent, then verifies it landed" {
  mktest::stub_function brew_core::setup_path
  STUB_RETURN=1 mktest::stub_function bootstrap::brew::_have "brew"
  mktest::stub_function bootstrap::brew::_log
  mktest::stub_function bootstrap::brew::_run_installer
  mktest::stub_function bootstrap::brew::_require "brew" "Homebrew installed but 'brew' not found on any standard prefix."
  bootstrap::brew::ensure
  mktest::assert_stub_called bootstrap::brew::_run_installer
  mktest::assert_stub_called bootstrap::brew::_require "brew" "Homebrew installed but 'brew' not found on any standard prefix."
}

# --- bootstrap::brew::_run_installer ---
#
# The island's only stdout is the resolved bash path; the installer's chatter is
# logging and must go to stderr, or it pollutes the path the dispatcher captures.
# The stub emits stdout chatter so the redirect is actually exercised.

@test "_run_installer drives the shared installer interactively, nothing on stdout" {
  mktest::stub_function bootstrap::brew::_interactive
  STUB_OUTPUT="installer chatter" mktest::stub_function brew_core::run_official_installer ""
  bootstrap::brew::_run_installer >"$BATS_TEST_TMPDIR/out" 2>/dev/null
  mktest::assert_stub_called brew_core::run_official_installer ""
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "_run_installer drives the shared installer non-interactively, nothing on stdout" {
  STUB_RETURN=1 mktest::stub_function bootstrap::brew::_interactive
  STUB_OUTPUT="installer chatter" mktest::stub_function brew_core::run_official_installer 1
  bootstrap::brew::_run_installer >"$BATS_TEST_TMPDIR/out" 2>/dev/null
  mktest::assert_stub_called brew_core::run_official_installer 1
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

# --- bootstrap::brew::install_bash ---
#
# Installs the bash formula; brew's summary/caveats are logging and must not reach
# stdout (they would corrupt the captured path). The stub records argv + the
# HOMEBREW_NO_ASK decision to files and prints chatter to stdout to exercise the
# redirect.

@test "install_bash installs the bash formula with HOMEBREW_NO_ASK when non-interactive, nothing on stdout" {
  brew() {
    printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/argv"
    printf '%s\n' "${HOMEBREW_NO_ASK:-}" >"$BATS_TEST_TMPDIR/noask"
    printf 'brew chatter\n'
  }
  STUB_RETURN=1 mktest::stub_function bootstrap::brew::_interactive
  mktest::stub_function bootstrap::brew::_require "brew" "Homebrew is not installed"
  bootstrap::brew::install_bash >"$BATS_TEST_TMPDIR/out" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = "install bash" ]
  [ "$(cat "$BATS_TEST_TMPDIR/noask")" = "1" ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "install_bash omits HOMEBREW_NO_ASK when interactive, nothing on stdout" {
  brew() {
    printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/argv"
    printf '%s\n' "${HOMEBREW_NO_ASK:-}" >"$BATS_TEST_TMPDIR/noask"
    printf 'brew chatter\n'
  }
  mktest::stub_function bootstrap::brew::_interactive
  mktest::stub_function bootstrap::brew::_require "brew" "Homebrew is not installed"
  bootstrap::brew::install_bash >"$BATS_TEST_TMPDIR/out" 2>/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = "install bash" ]
  [ "$(cat "$BATS_TEST_TMPDIR/noask")" = "" ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

# --- bootstrap::brew::bash_path ---

@test "bash_path is bash under the brew prefix" {
  brew() { echo /opt/test-brew; }
  run bootstrap::brew::bash_path
  [ "$output" = "/opt/test-brew/bin/bash" ]
}
