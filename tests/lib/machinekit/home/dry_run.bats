#!/usr/bin/env bats
# Tests for lib/machinekit/home.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/home/dry_run.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home/dry_run.sh"
  unset _MK_HOME_DRY_RUN_LOADED
  unset MACHINEKIT_CONFLICT_BEHAVIOR
  _MK_HOME_STAGING_DIR=""
  _MK_HOME_CTX_FILE=""
  _MK_HOME_DEST_REL=""
  _MK_HOME_IS_PRIVATE=0
  _MK_HOME_IS_TEMPLATE=0

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

@test "show_diff renders each staging file and shows the diff" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  _MK_HOME_CTX_FILE="dummy_file"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'foo\n' > "$_MK_HOME_STAGING_DIR/dot_1"
  printf 'bar\n' > "$_MK_HOME_STAGING_DIR/dot_2"
  STUB_OUTPUT="$_MK_HOME_STAGING_DIR" mktest::stub_function home::staging::dir
  mktest::stub_function home::_prepare_ctx
  mktest::stub_function home::dry_run::_render_to_outdir
  mktest::stub_function home::dry_run::_show_diff
  mktest::stub_function home::_cleanup_ctx
  STUB_OUTPUT="the-temp-dir" mktest::stub_function mktemp -d
  home::dry_run::show_diff
  mktest::assert_stub_called_in_order home::_prepare_ctx
  mktest::assert_stub_called_in_order home::dry_run::_render_to_outdir "$_MK_HOME_STAGING_DIR/dot_1" "$_MK_HOME_STAGING_DIR" "dummy_file" "the-temp-dir"
  mktest::assert_stub_called_in_order home::dry_run::_render_to_outdir "$_MK_HOME_STAGING_DIR/dot_2" "$_MK_HOME_STAGING_DIR" "dummy_file" "the-temp-dir"
  mktest::assert_stub_called_in_order home::dry_run::_show_diff "the-temp-dir"
  mktest::assert_stub_called_in_order home::_cleanup_ctx
}

# --- home::_render_to_outdir ---

@test "_render_to_outdir delegates to _render_file and writes output to the out_dir" {
  mktest::stub_function home::_decode_path
  _MK_HOME_DEST_REL=".zshrc"
  _MK_HOME_IS_TEMPLATE="maybe"
  local staging="$BATS_TEST_TMPDIR/staging"
  local out_dir="$BATS_TEST_TMPDIR/out"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  mkdir -p "$staging" "$out_dir"
  printf 'content\n' > "$staging/dot_zshrc"
  printf '{}' > "$ctx_file"
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'rendered\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file "$staging/dot_zshrc" "maybe" "$ctx_file"
  home::dry_run::_render_to_outdir "$staging/dot_zshrc" "$staging" "$ctx_file" "$out_dir"
  mktest::assert_stub_called_in_order home::_decode_path
  mktest::assert_stub_called_in_order home::_render_file "$staging/dot_zshrc" "maybe" "$ctx_file"
  [ "$(cat "$out_dir/.zshrc")" = "rendered" ]
}

@test "_render_to_outdir skips .mkignore itself" {
  mktest::stub_function home::_decode_path
  _MK_HOME_DEST_REL=".mkignore"
  local staging="$BATS_TEST_TMPDIR/staging"
  local out_dir="$BATS_TEST_TMPDIR/out"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  mkdir -p "$staging" "$out_dir"
  printf 'ignored\n' > "$staging/.mkignore"
  printf '{}' > "$ctx_file"
  mktest::stub_function home::_render_file
  home::dry_run::_render_to_outdir "$staging/.mkignore" "$staging" "$ctx_file" "$out_dir"
  mktest::assert_stub_not_called home::_render_file
}

@test "_render_to_outdir skips files listed in .mkignore" {
  mktest::stub_function home::_decode_path
  _MK_HOME_DEST_REL=".zshrc.local"
  local staging="$BATS_TEST_TMPDIR/staging"
  local out_dir="$BATS_TEST_TMPDIR/out"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  mkdir -p "$staging" "$out_dir"
  printf '.zshrc.local\n' > "$staging/.mkignore"
  printf 'local settings\n' > "$staging/dot_zshrc.local"
  printf '{}' > "$ctx_file"
  mktest::stub_function home::_render_file
  home::dry_run::_render_to_outdir "$staging/dot_zshrc.local" "$staging" "$ctx_file" "$out_dir"
  mktest::assert_stub_not_called home::_render_file
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
  mkdir -p "$staged"
  printf 'new content\n' > "$staged/newfile"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--color=always" "/dev/null" "$staged/newfile"
  result=$(home::dry_run::_generate_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_generate_diff returns git diff output for a file that differs from HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'new\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--color=always" "$HOME/file" "$staged/file"
  result=$(home::dry_run::_generate_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_generate_diff produces no output when files are unchanged" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'same\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'same\n' > "$HOME/file"
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
  mkdir -p "$staged"
  printf 'new\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--no-color" "$HOME/file" "$staged/file"
  result=$(home::dry_run::_show_plain_diff "$staged")
  [ "$result" = "diff output" ]
}

@test "_show_plain_diff outputs git diff content for new files not present in HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'content\n' > "$staged/newfile"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUB_OUTPUT="diff output" mktest::stub_function git "diff" "--no-index" "--no-color" "/dev/null" "$staged/newfile"
  result=$(home::dry_run::_show_plain_diff "$staged")
  [ "$result" = "diff output" ]
}
