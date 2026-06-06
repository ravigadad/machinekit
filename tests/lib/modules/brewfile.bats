#!/usr/bin/env bats
# Tests for lib/modules/brewfile.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/brewfile.sh
  source "$MACHINEKIT_DIR/lib/modules/brewfile.sh"

  # Logging collaborators — allow-only; logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::debug
}

# --- brewfile::install ---

@test "install routes common Brewfile through _apply_one" {
  local blueprints_dir="$BATS_TEST_TMPDIR/blueprints"
  STUB_OUTPUT="$blueprints_dir" mktest::stub_function blueprints::dir
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function brewfile::_apply_one
  brewfile::install
  mktest::assert_stub_called brewfile::_apply_one "$blueprints_dir/common/Brewfile" "common/Brewfile"
}

@test "install routes machine_type Brewfile through _apply_one when machine_type is set" {
  local blueprints_dir="$BATS_TEST_TMPDIR/blueprints"
  STUB_OUTPUT="$blueprints_dir" mktest::stub_function blueprints::dir
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  mktest::stub_function brewfile::_apply_one
  brewfile::install
  TIMES=2 mktest::assert_stub_called brewfile::_apply_one
  mktest::assert_stub_called brewfile::_apply_one "$blueprints_dir/common/Brewfile" "common/Brewfile"
  mktest::assert_stub_called brewfile::_apply_one "$blueprints_dir/machine_types/laptop/Brewfile" "machine_types/laptop/Brewfile"
}

@test "install skips machine_type Brewfile when machine_type is not set" {
  local blueprints_dir="$BATS_TEST_TMPDIR/blueprints"
  STUB_OUTPUT="$blueprints_dir" mktest::stub_function blueprints::dir
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function brewfile::_apply_one
  brewfile::install
  TIMES=1 mktest::assert_stub_called brewfile::_apply_one

}

# --- brewfile::_apply_one ---

@test "_apply_one returns 0 and skips brew bundle when Brewfile does not exist" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function brew "bundle"
  run brewfile::_apply_one "$BATS_TEST_TMPDIR/nonexistent/Brewfile" "common/Brewfile"
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called brew "bundle"
}

@test "_apply_one in dry-run calls _diff with the given Brewfile path" {
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'brew "git"\n' > "$brewfile"
  mktest::stub_function input::is_dry_run
  mktest::stub_function brewfile::_diff "$brewfile"
  brewfile::_apply_one "$brewfile" "common/Brewfile"
  mktest::assert_stub_called brewfile::_diff "$brewfile"
}

@test "_apply_one calls brew bundle with the Brewfile path when not dry-run" {
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'brew "git"\n' > "$brewfile"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function brew "bundle" "--file" "$brewfile"
  brewfile::_apply_one "$brewfile" "common/Brewfile"
  mktest::assert_stub_called brew "bundle" "--file" "$brewfile"
}

# --- brewfile::_diff ---

@test "diff skips when brew is not on PATH" {
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'brew "git"\n' > "$brewfile"
  run brewfile::_diff "$brewfile"
  [ "$status" -eq 0 ]
  MATCH="not installed" mktest::assert_stub_called logging::dry_run
}

@test "diff calls logging::dry_run for a formula that would be installed" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="jq" mktest::stub_function brew::_installed_formulae
  mktest::stub_function brew "list" "--cask"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'brew "git"\n' > "$brewfile"
  brewfile::_diff "$brewfile"
  MATCH="git" mktest::assert_stub_called logging::dry_run
}

@test "diff does not call logging::dry_run for a formula already installed" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="git" mktest::stub_function brew::_installed_formulae
  mktest::stub_function brew "list" "--cask"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'brew "git"\n' > "$brewfile"
  brewfile::_diff "$brewfile"
  mktest::assert_stub_not_called logging::dry_run
}

@test "diff calls logging::dry_run for a cask that would be installed" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="" mktest::stub_function brew::_installed_formulae
  mktest::stub_function brew "list" "--cask"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'cask "1password"\n' > "$brewfile"
  brewfile::_diff "$brewfile"
  MATCH="1password" mktest::assert_stub_called logging::dry_run
}

@test "diff does not call logging::dry_run for a cask already installed" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="" mktest::stub_function brew::_installed_formulae
  STUB_OUTPUT="1password" mktest::stub_function brew "list" "--cask"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf 'cask "1password"\n' > "$brewfile"
  brewfile::_diff "$brewfile"
  mktest::assert_stub_not_called logging::dry_run
}

@test "diff ignores comment lines and produces no output for them" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="" mktest::stub_function brew::_installed_formulae
  mktest::stub_function brew "list" "--cask"
  mktest::stub_function logging::dry_run
  local brewfile="$BATS_TEST_TMPDIR/Brewfile"
  printf '# just a comment\n' > "$brewfile"
  run brewfile::_diff "$brewfile"
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called logging::dry_run
}
