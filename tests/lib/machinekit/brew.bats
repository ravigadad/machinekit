#!/usr/bin/env bats
# Tests for lib/machinekit/brew.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/brew.sh
  source "$MACHINEKIT_DIR/lib/machinekit/brew.sh"
  _MK_BREW_FORMULAE_CACHED=0
  _MK_BREW_FORMULAE_CACHE=""
  unset _MK_BREW_LOADED

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::debug
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  # Functions defined by the first source are already present; second source is a no-op.
  brew::bootstrap() { echo "original"; }
  _MK_BREW_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/brew.sh"
  [ "$(brew::bootstrap)" = "original" ]
}

# --- brew::bootstrap ---

@test "bootstrap does not install when brew is already on PATH" {
  mktest::stub_function brew::_setup_path
  mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_install
  brew::bootstrap
  mktest::assert_stub_not_called brew::_install
}

@test "bootstrap installs when brew is not on PATH" {
  mktest::stub_function brew::_setup_path
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_install
  brew::bootstrap
  mktest::assert_stub_called brew::_install
}

# --- brew::install_formula ---

@test "install_formula fails with a clear error when homebrew is not installed" {
  mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::install_formula "git"
  MATCH="not installed" mktest::assert_stub_called lifecycle::fail
}

@test "install_formula skips when formula is already installed" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::is_formula_installed "git"
  mktest::stub_function brew "install" "git"
  brew::install_formula "git"
  mktest::assert_stub_not_called brew "install" "git"
}

@test "install_formula in dry-run reports a would-install message" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::is_formula_installed "someformula"
  mktest::stub_function logging::dry_run
  brew::install_formula "someformula"
  MATCH="someformula" mktest::assert_stub_called logging::dry_run
}

@test "install_formula calls brew install when formula is absent and not dry-run" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::is_formula_installed "git"
  mktest::stub_function brew "install" "git"
  brew::install_formula "git"
  mktest::assert_stub_called brew "install" "git"
}

@test "install_formula with --override-dry-run installs even in dry-run mode" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::is_formula_installed "git"
  mktest::stub_function brew "install" "git"
  brew::install_formula "git" --override-dry-run
  mktest::assert_stub_called brew "install" "git"
  mktest::assert_stub_not_called input::is_dry_run
}

@test "install_formula fails on an unknown option" {
  mktest::stub_function input::is_dry_run
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::install_formula "git" "--bad-flag"
  MATCH="unknown option" mktest::assert_stub_called lifecycle::fail
}

# --- brew::is_formula_installed ---

@test "is_formula_installed returns true for a formula in the list" {
  STUB_OUTPUT="$(printf 'git\njq\nage')" mktest::stub_function brew::_installed_formulae
  brew::is_formula_installed "jq"
}

@test "is_formula_installed returns false for a formula not in the list" {
  STUB_OUTPUT="$(printf 'git\njq')" mktest::stub_function brew::_installed_formulae
  run ! brew::is_formula_installed "age"
}

@test "is_formula_installed does not partial-match formula names" {
  STUB_OUTPUT="$(printf 'git\njq-extras')" mktest::stub_function brew::_installed_formulae
  run ! brew::is_formula_installed "jq"
}

# --- brew::_setup_path ---

@test "_setup_path does not fail when brew is absent from standard prefixes" {
  brew::_setup_path
}

# --- brew::_install ---

@test "_install runs the installer with NONINTERACTIVE=1 when not interactive" {
  # shellcheck disable=SC2016
  STUB_OUTPUT='echo brew_curled:$NONINTERACTIVE' mktest::stub_function curl "-fsSL" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function brew::_setup_path
  mktest::stub_function input::command_exists "brew"
  run --separate-stderr brew::_install
  [ "$status" -eq 0 ]
  [ "$output" = "brew_curled:1" ]
  mktest::assert_stub_called brew::_setup_path
}

@test "_install runs the installer without NONINTERACTIVE when interactive" {
  # shellcheck disable=SC2016
  STUB_OUTPUT='echo brew_curled:$NONINTERACTIVE' mktest::stub_function curl "-fsSL" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  mktest::stub_function input::is_interactive
  mktest::stub_function brew::_setup_path
  mktest::stub_function input::command_exists "brew"
  run --separate-stderr brew::_install
  [ "$status" -eq 0 ]
  [ "$output" = "brew_curled:" ]
  mktest::assert_stub_called brew::_setup_path
}

@test "_install fails when brew is not found after installing" {
  mktest::stub_function curl "-fsSL" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  mktest::stub_function input::is_interactive
  mktest::stub_function brew::_setup_path
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::_install
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

# --- brew::_installed_formulae ---

@test "_installed_formulae returns the list from brew list --formula" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="$(printf 'git\njq\nage')" mktest::stub_function brew "list" "--formula"
  result=$(brew::_installed_formulae)
  [ "$result" = "$(printf 'git\njq\nage')" ]
}

@test "_installed_formulae returns empty without caching when brew is not installed" {
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew "list" "--formula"
  result=$(brew::_installed_formulae)
  [ -z "$result" ]
  mktest::assert_stub_not_called brew "list" "--formula"
}

@test "_installed_formulae calls brew only once across repeated calls" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="git" mktest::stub_function brew "list" "--formula"
  brew::_installed_formulae >/dev/null
  brew::_installed_formulae >/dev/null
  TIMES=1 mktest::assert_stub_called brew "list" "--formula"
}
