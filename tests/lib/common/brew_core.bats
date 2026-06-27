#!/usr/bin/env bats
# Tests for lib/common/brew_core.sh — the opinion-free Homebrew primitives shared by
# the bootstrap (lib/bootstrap/brew.sh) and machinekit (lib/machinekit/brew.sh) layers.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/common/brew_core.sh
  source "$MACHINEKIT_DIR/lib/common/brew_core.sh"
}

# --- brew_core::setup_path ---

@test "setup_path runs without error whether or not brew is present" {
  brew_core::setup_path
}

# --- brew_core::run_official_installer ---

@test "run_official_installer runs the installer with NONINTERACTIVE when told to" {
  # shellcheck disable=SC2016
  STUB_OUTPUT='echo curled:$NONINTERACTIVE' mktest::stub_function curl "-fsSL" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  run brew_core::run_official_installer 1
  [ "$status" -eq 0 ]
  [ "$output" = "curled:1" ]
}

@test "run_official_installer runs without NONINTERACTIVE when not" {
  # shellcheck disable=SC2016
  STUB_OUTPUT='echo curled:$NONINTERACTIVE' mktest::stub_function curl "-fsSL" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  run brew_core::run_official_installer ""
  [ "$status" -eq 0 ]
  [ "$output" = "curled:" ]
}
