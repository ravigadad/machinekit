#!/usr/bin/env bats
# Tests for lib/modules/home.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/home.sh
  source "$MACHINEKIT_DIR/lib/modules/home.sh"
  unset _MK_HOME_LOADED
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

  STUB_OUTPUT="$BATS_TEST_TMPDIR/blueprints" mktest::stub_function blueprints::dir
  STUB_OUTPUT="$BATS_TEST_TMPDIR/mods" mktest::stub_function modules::dir
  mkdir -p "$BATS_TEST_TMPDIR/blueprints" "$BATS_TEST_TMPDIR/mods"
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::install() { echo "original"; }
  _MK_HOME_LOADED=1
  source "$MACHINEKIT_DIR/lib/modules/home.sh"
  [ "$(home::install)" = "original" ]
}

# --- home::staging_dir ---

@test "staging_dir fails before build_staging is called" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::staging_dir
  MATCH="before.*build_staging" mktest::assert_stub_called lifecycle::fail
}

# --- home::build_staging ---

@test "build_staging prepares the staging dir then layers module templates and blueprint home" {
  mktest::stub_function home::_prepare_staging_dir
  STUB_OUTPUT=$'git\nmise' mktest::stub_function context::get_array "modules.active"
  mktest::stub_function home::_layer_dir
  home::build_staging
  mktest::assert_stub_called home::_prepare_staging_dir
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/mods/git/templates" "git templates"
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/mods/mise/templates" "mise templates"
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

@test "build_staging layers only the blueprint home when no modules are active" {
  mktest::stub_function home::_prepare_staging_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  mktest::stub_function home::_layer_dir
  home::build_staging
  TIMES=1 mktest::assert_stub_called home::_layer_dir
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

# --- home::_prepare_staging_dir ---

@test "_prepare_staging_dir in dry-run creates a temp dir and registers cleanup" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  home::_prepare_staging_dir
  [ -d "$_MK_HOME_STAGING_DIR" ]
  mktest::assert_stub_called lifecycle::register_cleanup "home::cleanup_staging"
}

@test "_prepare_staging_dir in real mode creates a persistent dir under HOME and does not register cleanup" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  home::_prepare_staging_dir
  [ "$_MK_HOME_STAGING_DIR" = "$HOME/.local/share/machinekit/staging" ]
  [ -d "$_MK_HOME_STAGING_DIR" ]
  mktest::assert_stub_not_called lifecycle::register_cleanup
}

# --- home::_layer_dir ---

@test "_layer_dir copies the source contents into the staging dir" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'hello\n' > "$src/dotfile.txt"
  home::_layer_dir "$src" "test layer"
  [ -f "$_MK_HOME_STAGING_DIR/dotfile.txt" ]
}

@test "_layer_dir is a no-op when the source dir does not exist" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  home::_layer_dir "$BATS_TEST_TMPDIR/nonexistent" "absent layer"
  [ -z "$(ls -A "$_MK_HOME_STAGING_DIR")" ]
}

@test "_layer_dir overwrites an existing same-path file in the staging dir" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'old\n' > "$_MK_HOME_STAGING_DIR/config.txt"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'new\n' > "$src/config.txt"
  home::_layer_dir "$src" "override layer"
  [ "$(cat "$_MK_HOME_STAGING_DIR/config.txt")" = "new" ]
}

# --- home::cleanup_staging ---

@test "cleanup_staging removes the staging dir" {
  _MK_HOME_STAGING_DIR=$(mktemp -d)
  local staging="$_MK_HOME_STAGING_DIR"
  home::cleanup_staging
  [ ! -d "$staging" ]
}

# --- home::_decode_path ---

@test "_decode_path passes a plain filename through unchanged" {
  home::_decode_path "env.zsh"
  [ "$_MK_HOME_DEST_REL" = "env.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
  [ "$_MK_HOME_IS_TEMPLATE" = "0" ]
}

@test "_decode_path converts dot_ prefix to a leading dot" {
  home::_decode_path "dot_zshrc"
  [ "$_MK_HOME_DEST_REL" = ".zshrc" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path strips .tmpl suffix and sets is_template" {
  home::_decode_path "dot_gitconfig.tmpl"
  [ "$_MK_HOME_DEST_REL" = ".gitconfig" ]
  [ "$_MK_HOME_IS_TEMPLATE" = "1" ]
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
  home::_decode_path "private_dot_ssh/private_config.tmpl"
  [ "$_MK_HOME_DEST_REL" = ".ssh/config" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
  [ "$_MK_HOME_IS_TEMPLATE" = "1" ]
}

@test "_decode_path decodes a deep path preserving intermediate directories" {
  home::_decode_path "dot_config/machinekit/env.zsh.d/mise.zsh"
  [ "$_MK_HOME_DEST_REL" = ".config/machinekit/env.zsh.d/mise.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
  [ "$_MK_HOME_IS_TEMPLATE" = "0" ]
}

# --- home::_apply_file ---

@test "_apply_file skips .mkignore itself" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf '.zshrc.local\n' > "$_MK_HOME_STAGING_DIR/.mkignore"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/.mkignore" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  [ ! -f "$HOME/.mkignore" ]
}

@test "_apply_file skips files listed in .mkignore" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf '.zshrc.local\n' > "$_MK_HOME_STAGING_DIR/.mkignore"
  printf 'local settings\n' > "$_MK_HOME_STAGING_DIR/dot_zshrc.local"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_zshrc.local" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  [ ! -f "$HOME/.zshrc.local" ]
}

@test "_apply_file copies a non-template file to the decoded destination" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'content\n' > "$_MK_HOME_STAGING_DIR/dot_zshrc"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_zshrc" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  [ -f "$HOME/.zshrc" ]
  [ "$(cat "$HOME/.zshrc")" = "content" ]
}

@test "_apply_file renders a .tmpl file via gomplate and writes output to the destination" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'template\n' > "$_MK_HOME_STAGING_DIR/dot_gitconfig.tmpl"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  STUB_OUTPUT="rendered" mktest::stub_function gomplate
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_gitconfig.tmpl" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called gomplate
  [ -f "$HOME/.gitconfig" ]
  [ "$(cat "$HOME/.gitconfig")" = "rendered" ]
}

@test "_apply_file sets mode 600 on a file with private_ in its path" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  local ssh_staging="$_MK_HOME_STAGING_DIR/private_dot_ssh"
  mkdir -p "$ssh_staging"
  printf 'Host *\n' > "$ssh_staging/private_config"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$ssh_staging/private_config" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  [ -f "$HOME/.ssh/config" ]
  [ "$(stat -f '%A' "$HOME/.ssh/config")" = "600" ]
}

@test "_apply_file sets mode 700 on a directory whose staging name had private_ prefix" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  local ssh_staging="$_MK_HOME_STAGING_DIR/private_dot_ssh"
  mkdir -p "$ssh_staging"
  printf 'Host *\n' > "$ssh_staging/private_config"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$ssh_staging/private_config" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  [ "$(stat -f '%A' "$HOME/.ssh")" = "700" ]
}

# --- home::_show_diff ---

@test "_show_diff delegates to _show_interactive_diff when interactive" {
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_show_interactive_diff
  home::_show_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::_show_interactive_diff "$BATS_TEST_TMPDIR"
}

@test "_show_diff delegates to _show_plain_diff when not interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function home::_show_plain_diff
  home::_show_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::_show_plain_diff "$BATS_TEST_TMPDIR"
}

# --- home::_generate_diff ---

@test "_generate_diff calls git diff for a new file not present in HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'new content\n' > "$staged/newfile"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  mktest::stub_function git
  home::_generate_diff "$staged"
  MATCH="--no-index" mktest::assert_stub_called git
}

@test "_generate_diff calls git diff for a file that differs from HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'new\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  mktest::stub_function git
  home::_generate_diff "$staged"
  MATCH="--no-index" mktest::assert_stub_called git
}

@test "_generate_diff produces no output when files are unchanged" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'same\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'same\n' > "$HOME/file"
  mktest::stub_function git
  home::_generate_diff "$staged"
  mktest::assert_stub_not_called git
}

# --- home::_show_interactive_diff ---

@test "_show_interactive_diff logs no-changes when generate_diff produces nothing" {
  mktest::stub_function home::_generate_diff
  home::_show_interactive_diff "$BATS_TEST_TMPDIR"
  MATCH="No changes" mktest::assert_stub_called logging::info
}

@test "_show_interactive_diff logs no-changes and does not call _page_diff when diff is empty" {
  mktest::stub_function home::_generate_diff
  mktest::stub_function home::_page_diff
  home::_show_interactive_diff "$BATS_TEST_TMPDIR"
  MATCH="No changes" mktest::assert_stub_called logging::info
  mktest::assert_stub_not_called home::_page_diff
}

@test "_show_interactive_diff calls _page_diff when there are changes" {
  STUB_OUTPUT="some diff content" mktest::stub_function home::_generate_diff
  mktest::stub_function home::_page_diff
  home::_show_interactive_diff "$BATS_TEST_TMPDIR"
  mktest::assert_stub_called home::_page_diff
}

# --- home::_page_diff ---

@test "_page_diff prompts then opens less -R with the diff file" {
  printf 'x' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  mktest::stub_function less
  local diff_file="$BATS_TEST_TMPDIR/diff.txt"
  printf 'some diff\n' > "$diff_file"
  home::_page_diff "$diff_file"
  MATCH="-R" mktest::assert_stub_called less
}

# --- home::_show_plain_diff ---

@test "_show_plain_diff logs no-changes when staging dir is empty" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  home::_show_plain_diff "$staged"
  MATCH="No changes" mktest::assert_stub_called logging::info
}

@test "_show_plain_diff calls git diff for changed files" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'new\n' > "$staged/file"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  printf 'old\n' > "$HOME/file"
  mktest::stub_function git
  home::_show_plain_diff "$staged"
  MATCH="--no-index" mktest::assert_stub_called git
}

@test "_show_plain_diff calls git diff for new files not present in HOME" {
  local staged="$BATS_TEST_TMPDIR/staged"
  mkdir -p "$staged"
  printf 'content\n' > "$staged/newfile"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  mktest::stub_function git
  home::_show_plain_diff "$staged"
  MATCH="--no-index" mktest::assert_stub_called git
}

# --- home::install ---

@test "install in dry-run delegates to _diff" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function home::build_staging
  mktest::stub_function home::_diff
  home::install
  mktest::assert_stub_called home::_diff
}

@test "install in real mode calls build_staging then _apply" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function home::build_staging
  mktest::stub_function home::_apply
  home::install
  mktest::assert_stub_called home::build_staging
  mktest::assert_stub_called home::_apply
}
