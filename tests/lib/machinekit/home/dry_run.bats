#!/usr/bin/env bats
# Tests for lib/machinekit/home.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/home/dry_run.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home/dry_run.sh"
  unset _MK_HOME_DRY_RUN_LOADED
  unset MACHINEKIT_CONFLICT_BEHAVIOR
  _MK_HOME_STAGING_DIR=""
  _MK_HOME_DEST_PATH=""
  _MK_HOME_IS_PRIVATE=0

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::warn
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::dry_run::show_diff() { echo "original"; }
  _MK_HOME_DRY_RUN_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home/dry_run.sh"
  [ "$(home::dry_run::show_diff)" = "original" ]
}

# --- home::dry_run::show_diff ---

@test "show_diff renders the planned files into a temp dir and shows the diff" {
  STUB_OUTPUT="the-temp-dir" mktest::stub_function mktemp -d
  mktest::stub_function home::_each_planned_file
  mktest::stub_function home::dry_run::_show_diff
  home::dry_run::show_diff
  mktest::assert_stub_called home::_each_planned_file home::dry_run::_render_to_outdir "the-temp-dir"
  mktest::assert_stub_called home::dry_run::_show_diff "the-temp-dir"
}

# --- home::_render_to_outdir ---

@test "_render_to_outdir executes the pipeline and mirrors the absolute dest under out_dir" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local content="$BATS_TEST_TMPDIR/rendered"
  printf 'rendered\n' > "$content"
  STUB_OUTPUT="$content" mktest::stub_function home::transforms::execute
  local out_dir="$BATS_TEST_TMPDIR/out"
  mkdir -p "$out_dir"
  # (out_dir, src, src_rel, dest, key, private, suppressed, pipeline…)
  home::dry_run::_render_to_outdir "$out_dir" "/staging/dot_zshrc.tmpl" "dot_zshrc.tmpl" "$HOME/.zshrc" ".zshrc" "0" "false" "gomplate::render"
  mktest::assert_stub_called home::transforms::execute "/staging/dot_zshrc.tmpl" "gomplate::render"
  [ "$(cat "$out_dir/${HOME#/}/.zshrc")" = "rendered" ]
}

@test "_render_to_outdir skips a suppressed file: logs it and does not execute" {
  mktest::stub_function home::transforms::execute
  local out_dir="$BATS_TEST_TMPDIR/out"
  mkdir -p "$out_dir"
  home::dry_run::_render_to_outdir "$out_dir" "/s/x" "x" "/h/x" ".x" "0" "true" "gomplate::render"
  mktest::assert_stub_not_called home::transforms::execute
  MATCH="\.x" mktest::assert_stub_called logging::debug
}

# --- home::_show_diff ---

@test "_show_diff delegates to _show_interactive_diff when interactive" {
  mktest::stub_function input::is_interactive
  mktest::stub_function home::dry_run::_show_interactive_diff
  home::dry_run::_show_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::dry_run::_show_interactive_diff "$BATS_TEST_TMPDIR"
}

@test "_show_diff delegates to _show_plain_diff when not interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function home::dry_run::_show_plain_diff
  home::dry_run::_show_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::dry_run::_show_plain_diff "$BATS_TEST_TMPDIR"
}

# --- home::_show_interactive_diff ---

@test "_show_interactive_diff logs no-changes and does not call _page_diff when diff is empty" {
  mktest::stub_function home::dry_run::_generate_diff
  mktest::stub_function home::dry_run::_page_diff
  home::dry_run::_show_interactive_diff "$BATS_TEST_TMPDIR"
  MATCH="No changes" mktest::assert_stub_called logging::info
  mktest::assert_stub_not_called home::dry_run::_page_diff
}

@test "_show_interactive_diff calls _page_diff when there are changes" {
  STUB_OUTPUT="some diff content" mktest::stub_function home::dry_run::_generate_diff
  mktest::stub_function home::dry_run::_page_diff
  home::dry_run::_show_interactive_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::dry_run::_page_diff
}

# --- home::_generate_diff ---

@test "_generate_diff returns git diff output for a new file not present in HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # The preview mirrors the absolute destination ($HOME/newfile) with the
  # leading slash stripped — that is how _render_to_outdir laid it down.
  local preview="$staged/${HOME#/}"
  mkdir -p "$preview"
  printf 'new content\n' > "$preview/newfile"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--color=always" "/dev/null" "$preview/newfile"
  result=$(home::dry_run::_generate_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_generate_diff returns git diff output for a file that differs from HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  local preview="$staged/${HOME#/}"
  mkdir -p "$preview"
  printf 'new\n' > "$preview/file"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--color=always" "$HOME/file" "$preview/file"
  result=$(home::dry_run::_generate_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_generate_diff produces no output when files are unchanged" {
  local staged="$BATS_TEST_TMPDIR/staged"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'same\n' > "$HOME/file"
  local preview="$staged/${HOME#/}"
  mkdir -p "$preview"
  printf 'same\n' > "$preview/file"
  mktest::stub_function git
  result=$(home::dry_run::_generate_diff "$staged")
  [ -z "$result" ]
  mktest::assert_stub_not_called git
}

# --- home::_page_diff ---

@test "_page_diff prompts then opens less -R with the diff file" {
  printf 'x' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  mktest::stub_function less
  local diff_file="$BATS_TEST_TMPDIR/diff.txt"
  printf 'some diff\n' > "$diff_file"
  home::dry_run::_page_diff "$diff_file"
  MATCH="-R" mktest::assert_stub_called less
}

# --- home::_show_plain_diff ---

@test "_show_plain_diff logs no-changes when staging dir is empty" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  home::dry_run::_show_plain_diff "$staged"
  MATCH="No changes" mktest::assert_stub_called logging::info
}

@test "_show_plain_diff outputs git diff content for changed files" {
  local staged="$BATS_TEST_TMPDIR/staged"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  local preview="$staged/${HOME#/}"
  mkdir -p "$preview"
  printf 'new\n' > "$preview/file"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--no-color" "$HOME/file" "$preview/file"
  result=$(home::dry_run::_show_plain_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_show_plain_diff outputs git diff content for new files not present in HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local preview="$staged/${HOME#/}"
  mkdir -p "$preview"
  printf 'content\n' > "$preview/newfile"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--no-color" "/dev/null" "$preview/newfile"
  result=$(home::dry_run::_show_plain_diff "$staged")
  [ "$result" = "diff output" ]
}
