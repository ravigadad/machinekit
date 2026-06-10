#!/usr/bin/env bats
# Tests for lib/machinekit/home.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

# Portable file-mode query: BSD stat uses -f '%A', GNU stat uses -c '%a'.
_file_mode() { command stat -c '%a' "$1" 2>/dev/null || command stat -f '%A' "$1"; }

setup() {
  # shellcheck source=../../../lib/machinekit/home.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home.sh"
  unset _MK_HOME_LOADED
  unset MACHINEKIT_CONFLICT_BEHAVIOR
  _MK_HOME_STAGING_DIR=""
  _MK_HOME_DEST_REL=""
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
  home::sync() { echo "original"; }
  _MK_HOME_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home.sh"
  [ "$(home::sync)" = "original" ]
}

# --- home::sync ---

@test "sync in dry-run calls dry_run::show_diff and not _apply" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function home::staging::build
  mktest::stub_function home::dry_run::show_diff
  mktest::stub_function home::_apply
  home::sync
  mktest::assert_stub_called_in_order home::staging::build
  mktest::assert_stub_called_in_order home::dry_run::show_diff
  mktest::assert_stub_not_called home::_apply
}

@test "sync in real mode calls staging::build then _apply" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function home::staging::build
  mktest::stub_function home::dry_run::show_diff
  mktest::stub_function home::_apply
  home::sync
  mktest::assert_stub_called_in_order home::staging::build
  mktest::assert_stub_called_in_order home::_apply
  mktest::assert_stub_not_called home::dry_run::show_diff
}

# --- home::_apply ---

@test "_apply calls _apply_file for each file in staging" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'foo\n' > "$_MK_HOME_STAGING_DIR/dot_1"
  printf 'bar\n' > "$_MK_HOME_STAGING_DIR/dot_2"
  STUB_OUTPUT="$_MK_HOME_STAGING_DIR" mktest::stub_function home::staging::dir
  mktest::stub_function home::_apply_file
  home::_apply
  mktest::assert_stub_called_in_order home::_apply_file "$_MK_HOME_STAGING_DIR/dot_1" "$_MK_HOME_STAGING_DIR"
  mktest::assert_stub_called_in_order home::_apply_file "$_MK_HOME_STAGING_DIR/dot_2" "$_MK_HOME_STAGING_DIR"
}

# --- home::_apply_file ---

@test "_apply_file skips .mkignore itself, without executing or reconciling" {
  mktest::stub_function home::_decode_path
  mktest::stub_function home::transforms::resolve
  mktest::stub_function home::transforms::execute
  mktest::stub_function home::_reconcile_file
  _MK_HOME_TRANSFORM_DEST=".mkignore"
  home::_apply_file "/staging/.mkignore" "/staging"
  mktest::assert_stub_not_called home::transforms::execute
  mktest::assert_stub_not_called home::_reconcile_file
}

@test "_apply_file skips a file listed in .mkignore, without executing or reconciling" {
  mktest::stub_function home::_decode_path
  mktest::stub_function home::transforms::resolve
  mktest::stub_function home::transforms::execute
  mktest::stub_function home::_reconcile_file
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  printf '.zshrc.local\n' > "$staging/.mkignore"
  _MK_HOME_TRANSFORM_DEST=".zshrc.local"
  home::_apply_file "$staging/dot_zshrc.local" "$staging"
  mktest::assert_stub_not_called home::transforms::execute
  mktest::assert_stub_not_called home::_reconcile_file
}

@test "_apply_file resolves the decoded path, executes the pipeline, and reconciles the result" {
  mktest::stub_function home::_decode_path
  mktest::stub_function home::transforms::resolve
  mktest::stub_function home::transforms::execute
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  _MK_HOME_DEST_REL=".gitconfig.tmpl"
  _MK_HOME_TRANSFORM_DEST=".gitconfig"
  _MK_HOME_TRANSFORM_CONTENT="$BATS_TEST_TMPDIR/rendered"
  home::_apply_file "$staging/dot_gitconfig.tmpl" "$staging"
  mktest::assert_stub_called home::_decode_path "dot_gitconfig.tmpl"
  mktest::assert_stub_called home::transforms::resolve ".gitconfig.tmpl"
  mktest::assert_stub_called home::transforms::execute "$staging/dot_gitconfig.tmpl"
  mktest::assert_stub_called home::_reconcile_file "$BATS_TEST_TMPDIR/rendered" "$HOME/.gitconfig" ".gitconfig" "0"
}

@test "_apply_file forwards is_private and the parent path for a private nested file" {
  mktest::stub_function home::_decode_path
  mktest::stub_function home::transforms::resolve
  mktest::stub_function home::transforms::execute
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging/private_dot_ssh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  _MK_HOME_IS_PRIVATE=1
  _MK_HOME_TRANSFORM_DEST=".ssh/config"
  _MK_HOME_TRANSFORM_CONTENT="$BATS_TEST_TMPDIR/rendered"
  home::_apply_file "$staging/private_dot_ssh/private_config" "$staging"
  mktest::assert_stub_called home::_reconcile_file "$BATS_TEST_TMPDIR/rendered" "$HOME/.ssh/config" ".ssh/config" "1"
  mktest::assert_stub_called home::_apply_parent_perms "private_dot_ssh/private_config" "$HOME/.ssh/config"
}

# --- home::_decode_path ---

@test "_decode_path passes a plain filename through unchanged" {
  home::_decode_path "env.zsh"
  [ "$_MK_HOME_DEST_REL" = "env.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path converts dot_ prefix to a leading dot" {
  home::_decode_path "dot_zshrc"
  [ "$_MK_HOME_DEST_REL" = ".zshrc" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path strips private_ prefix and sets is_private" {
  home::_decode_path "private_config"
  [ "$_MK_HOME_DEST_REL" = "config" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path handles combined private_dot_ prefix" {
  home::_decode_path "private_dot_ssh"
  [ "$_MK_HOME_DEST_REL" = ".ssh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path decodes a nested path with all conventions" {
  home::_decode_path "private_dot_ssh/private_config"
  [ "$_MK_HOME_DEST_REL" = ".ssh/config" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path decodes a deep path preserving intermediate directories" {
  home::_decode_path "dot_config/machinekit/env.zsh.d/mise.zsh"
  [ "$_MK_HOME_DEST_REL" = ".config/machinekit/env.zsh.d/mise.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

# --- home::_apply_parent_perms ---

@test "_apply_parent_perms sets mode 700 on dest parent when staging parent has private_ prefix" {
  local dest_dir="$BATS_TEST_TMPDIR/home/.ssh"
  mkdir -p "$dest_dir"
  home::_apply_parent_perms "private_dot_ssh/config" "$BATS_TEST_TMPDIR/home/.ssh/config"
  [ "$(_file_mode "$dest_dir")" = "700" ]
}

@test "_apply_parent_perms does not chmod when staging parent has no private_ prefix" {
  local dest_dir="$BATS_TEST_TMPDIR/home/.config"
  mkdir -p "$dest_dir"
  chmod 755 "$dest_dir"
  home::_apply_parent_perms "dot_config/settings" "$BATS_TEST_TMPDIR/home/.config/settings"
  [ "$(_file_mode "$dest_dir")" = "755" ]
}

@test "_apply_parent_perms is a no-op for a top-level file with no parent component" {
  mktest::stub_function chmod
  home::_apply_parent_perms "dot_zshrc" "$BATS_TEST_TMPDIR/home/.zshrc"
  mktest::assert_stub_not_called chmod
}

# --- home::_reconcile_file ---

@test "_reconcile_file writes a new file directly, without conflict resolution" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  printf 'content\n' > "$resolved"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
  mktest::assert_stub_not_called home::_conflict_action
}

@test "_reconcile_file skips the write and removes the resolved temp when content is unchanged" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'content\n' > "$resolved"
  printf 'content\n' > "$dest"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_not_called home::_write_file
  mktest::assert_stub_not_called home::_conflict_action
  [ ! -f "$resolved" ]
}

@test "_reconcile_file writes when content differs and _conflict_action returns true" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  STUB_RETURN=0 mktest::stub_function home::_conflict_action ".zshrc" "$resolved" "$dest"
  mktest::stub_function home::_write_file
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
}

@test "_reconcile_file does not write when _conflict_action returns skip" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  STUB_RETURN=1 mktest::stub_function home::_conflict_action ".zshrc" "$resolved" "$dest"
  mktest::stub_function home::_write_file
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_not_called home::_write_file
}

# --- home::_write_file ---

@test "_write_file copies resolved to dest_path" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "0"
  [ "$(cat "$dest")" = "content" ]
}

@test "_write_file removes the resolved temp file after copying" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "0"
  [ ! -f "$src" ]
}

@test "_write_file sets mode 600 on dest when is_private is 1" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "1"
  [ "$(_file_mode "$dest")" = "600" ]
}

# --- home::_conflict_action ---

@test "_conflict_action returns 0 when conflict_behavior is overwrite" {
  STUB_OUTPUT="overwrite" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
}

@test "_conflict_action returns 1 when conflict_behavior is skip" {
  STUB_OUTPUT="skip" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
}

@test "_conflict_action calls lifecycle::fail when conflict_behavior is abort" {
  STUB_OUTPUT="abort" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="conflict" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action calls lifecycle::fail for unknown conflict_behavior value" {
  STUB_OUTPUT="bogus" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="unknown" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action defaults to overwrite when behavior is empty and not interactive" {
  mktest::stub_function input::conflict_behavior
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_not_called home::_prompt_conflict
}

@test "_conflict_action delegates to _prompt_conflict when behavior is empty and interactive" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="overwrite" mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called home::_prompt_conflict ".zshrc"
}

@test "_conflict_action calls lifecycle::fail when _prompt_conflict returns abort" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="abort" mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="abort" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action propagates skip from _prompt_conflict" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="skip" mktest::stub_function home::_prompt_conflict
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
}

@test "_conflict_action calls _show_conflict_diff and re-prompts when _prompt_conflict returns diff" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_show_conflict_diff
  local call_count_file="$BATS_TEST_TMPDIR/call_count"
  printf '0' > "$call_count_file"
  home::_prompt_conflict() {
    local n
    n=$(cat "$call_count_file")
    n=$((n + 1))
    printf '%d' "$n" > "$call_count_file"
    if [ "$n" -eq 1 ]; then printf 'diff\n'; else printf 'overwrite\n'; fi
  }
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called home::_show_conflict_diff \
    "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
}

@test "_conflict_action exports overwrite and returns 0 when _prompt_conflict echoes overwrite-all" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="overwrite-all" mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$MACHINEKIT_CONFLICT_BEHAVIOR" = "overwrite" ]
}

@test "_conflict_action exports skip and returns 1 when _prompt_conflict echoes skip-all" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="skip-all" mktest::stub_function home::_prompt_conflict
  local result=0
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest" \
    || result=$?
  [ "$result" -eq 1 ]
  [ "$MACHINEKIT_CONFLICT_BEHAVIOR" = "skip" ]
}

# --- home::_prompt_conflict ---

@test "_prompt_conflict echoes overwrite for o choice" {
  STUB_OUTPUT="o" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite" ]
}

@test "_prompt_conflict echoes skip for s choice" {
  STUB_OUTPUT="s" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "skip" ]
}

@test "_prompt_conflict echoes abort for a choice" {
  STUB_OUTPUT="a" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "abort" ]
}

@test "_prompt_conflict echoes diff for d choice" {
  STUB_OUTPUT="d" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "diff" ]
}

@test "_prompt_conflict echoes overwrite-all for O choice" {
  STUB_OUTPUT="O" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite-all" ]
}

@test "_prompt_conflict echoes skip-all for S choice" {
  STUB_OUTPUT="S" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "skip-all" ]
}

@test "_prompt_conflict re-prompts and warns on an invalid choice" {
  local call_count_file="$BATS_TEST_TMPDIR/call_count"
  printf '0' > "$call_count_file"
  home::_read_conflict_choice() {
    local n; n=$(cat "$call_count_file")
    n=$((n + 1))
    printf '%d' "$n" > "$call_count_file"
    if [ "$n" -eq 1 ]; then printf 'x'; else printf 'o'; fi
  }
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite" ]
  MATCH="invalid" mktest::assert_stub_called logging::warn
}

# --- home::_read_conflict_choice ---

@test "_read_conflict_choice reads one character from MACHINEKIT_TTY" {
  printf 'o' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(home::_read_conflict_choice)
  [ "$result" = "o" ]
}

# --- home::_show_conflict_diff ---

@test "_show_conflict_diff calls git diff and pipes output to less when files differ" {
  STUB_OUTPUT="diff content" mktest::stub_function git diff --no-index --color=always "the-dest" "the-source"
  mktest::stub_function less
  home::_show_conflict_diff "the-source" "the-dest"
  mktest::assert_stub_called less
}

@test "_show_conflict_diff does not open less when diff is empty" {
  STUB_OUTPUT="" mktest::stub_function git diff --no-index --color=always "the-dest" "the-source"
  mktest::stub_function less
  home::_show_conflict_diff "the-source" "the-dest"
  mktest::assert_stub_not_called less
}

