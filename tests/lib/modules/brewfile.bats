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

@test "install returns 0 and skips brew bundle when no Brewfile exists" {
  mktest::stub_function blueprints::dir "$BATS_TEST_TMPDIR/blueprints"
  mktest::stub_function input::is_dry_run
  mktest::stub_function brew "bundle"
  run brewfile::install
  [ "$status" -eq 0 ]
  mktest::assert_stub_not_called brew "bundle"
}

@test "install in dry-run calls diff with the blueprints Brewfile path" {
  local blueprints_dir="$BATS_TEST_TMPDIR/blueprints"
  mkdir -p "$blueprints_dir/common"
  printf 'brew "git"\n' > "$blueprints_dir/common/Brewfile"
  STUB_OUTPUT="$blueprints_dir" mktest::stub_function blueprints::dir
  mktest::stub_function input::is_dry_run
  mktest::stub_function brewfile::_diff "$blueprints_dir/common/Brewfile"
  brewfile::install
  mktest::assert_stub_called brewfile::_diff "$blueprints_dir/common/Brewfile"
}

@test "install calls brew bundle with the blueprints Brewfile path when not dry-run" {
  local blueprints_dir="$BATS_TEST_TMPDIR/blueprints"
  mkdir -p "$blueprints_dir/common"
  local brewfile_path="$blueprints_dir/common/Brewfile"
  printf 'brew "git"\n' > "$brewfile_path"
  STUB_OUTPUT="$blueprints_dir" mktest::stub_function blueprints::dir
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function brew "bundle" "--file" "$brewfile_path"
  brewfile::install
  mktest::assert_stub_called brew "bundle" "--file" "$brewfile_path"
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
