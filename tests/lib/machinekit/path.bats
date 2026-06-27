#!/usr/bin/env bats
# Tests for lib/machinekit/path.sh — putting the public `machinekit` command on
# the user's PATH: a ~/.local/bin symlink plus an idempotent rc PATH line, with a
# consent opt-out and a printed-instructions fallback.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/path.sh
  source "$MACHINEKIT_DIR/lib/machinekit/path.sh"
}

# --- path::ensure_on_path ---

@test "ensure_on_path links the command and writes the rc PATH line" {
  mktest::stub_function path::_link
  STUB_OUTPUT="zsh" mktest::stub_function path::_detect_shell
  STUB_OUTPUT="fake-rc-file" mktest::stub_function path::_rc_file "zsh"
  STUB_OUTPUT="fake-export-line" mktest::stub_function path::_export_line "zsh"
  mktest::stub_function path::_write_path_block "fake-rc-file" "fake-export-line"
  mktest::stub_function path::_print_manual_instructions
  mktest::stub_function logging::success
  mktest::stub_function logging::info

  path::ensure_on_path 1

  mktest::assert_stub_called path::_link "$MACHINEKIT_DIR"
  mktest::assert_stub_called path::_write_path_block "fake-rc-file" "fake-export-line"
  mktest::assert_stub_not_called path::_print_manual_instructions
}

@test "ensure_on_path links but skips the rc edit when the user opts out" {
  mktest::stub_function path::_link
  mktest::stub_function path::_rc_file
  mktest::stub_function path::_write_path_block
  mktest::stub_function path::_print_manual_instructions

  path::ensure_on_path 0

  mktest::assert_stub_called path::_link "$MACHINEKIT_DIR"
  mktest::assert_stub_called path::_print_manual_instructions
  mktest::assert_stub_not_called path::_rc_file
  mktest::assert_stub_not_called path::_write_path_block
}

@test "ensure_on_path falls back to instructions for an unknown shell" {
  mktest::stub_function path::_link
  STUB_OUTPUT="elvish" mktest::stub_function path::_detect_shell
  STUB_OUTPUT="" mktest::stub_function path::_rc_file "elvish"
  mktest::stub_function path::_write_path_block
  mktest::stub_function path::_print_manual_instructions

  path::ensure_on_path 1

  mktest::assert_stub_called path::_print_manual_instructions
  mktest::assert_stub_not_called path::_write_path_block
}

# --- path::_link ---

@test "_link symlinks the public entry into the local bin dir" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/bin" mktest::stub_function path::_local_bin_dir
  path::_link "/fake/framework"
  [ -L "$BATS_TEST_TMPDIR/bin/machinekit" ]
  [ "$(readlink "$BATS_TEST_TMPDIR/bin/machinekit")" = "/fake/framework/bin/machinekit" ]
}

@test "_link re-points an existing link to heal a moved framework" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/bin" mktest::stub_function path::_local_bin_dir
  path::_link "/old/framework"
  path::_link "/new/framework"
  [ "$(readlink "$BATS_TEST_TMPDIR/bin/machinekit")" = "/new/framework/bin/machinekit" ]
}

# --- path::_local_bin_dir ---

@test "_local_bin_dir is ~/.local/bin under HOME" {
  HOME=/fake/home
  run path::_local_bin_dir
  [ "$output" = "/fake/home/.local/bin" ]
}

# --- path::_detect_shell ---

@test "_detect_shell is the basename of \$SHELL" {
  SHELL=/usr/bin/zsh
  run path::_detect_shell
  [ "$output" = "zsh" ]
}

@test "_detect_shell is empty when \$SHELL is unset" {
  unset SHELL
  run path::_detect_shell
  [ "$output" = "" ]
}

# --- path::_rc_file ---

@test "_rc_file for zsh is ~/.zshrc" {
  HOME=/fake/home
  run path::_rc_file zsh
  [ "$output" = "/fake/home/.zshrc" ]
}

@test "_rc_file for fish is config.fish" {
  HOME=/fake/home
  run path::_rc_file fish
  [ "$output" = "/fake/home/.config/fish/config.fish" ]
}

@test "_rc_file for bash defaults to ~/.bashrc when none exist" {
  HOME="$BATS_TEST_TMPDIR"
  run path::_rc_file bash
  [ "$output" = "$BATS_TEST_TMPDIR/.bashrc" ]
}

@test "_rc_file for bash prefers an rc the user already has" {
  HOME="$BATS_TEST_TMPDIR"
  touch "$HOME/.bash_profile"
  run path::_rc_file bash
  [ "$output" = "$BATS_TEST_TMPDIR/.bash_profile" ]
}

@test "_rc_file is empty for a shell we do not wire" {
  HOME=/fake/home
  run path::_rc_file elvish
  [ "$output" = "" ]
}

# --- path::_export_line ---

@test "_export_line is a POSIX export by default" {
  run path::_export_line zsh
  [ "$output" = 'export PATH="$HOME/.local/bin:$PATH"' ]
}

@test "_export_line uses fish syntax for fish" {
  run path::_export_line fish
  [ "$output" = 'set -gx PATH $HOME/.local/bin $PATH' ]
}

# --- path::_write_path_block ---

@test "_write_path_block reconciles the PATH line as a managed block" {
  managed_block::ensure() {
    printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/args"
    cat >"$BATS_TEST_TMPDIR/stdin"
  }
  path::_write_path_block "/fake/rc" "fake-export-line"
  diff "$BATS_TEST_TMPDIR/args" - <<EOF
/fake/rc
#
EOF
  [ "$(cat "$BATS_TEST_TMPDIR/stdin")" = "fake-export-line" ]
}

# --- path::_print_manual_instructions ---

@test "_print_manual_instructions points the user at the local bin link" {
  STUB_OUTPUT="/fake/bin-dir" mktest::stub_function path::_local_bin_dir
  mktest::stub_function logging::info
  path::_print_manual_instructions
  MATCH="/fake/bin-dir" mktest::assert_stub_called logging::info
}
