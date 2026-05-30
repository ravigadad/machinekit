#!/usr/bin/env bats
# Tests for lib/modules/chezmoi.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/chezmoi.sh
  source "$MACHINEKIT_DIR/lib/modules/chezmoi.sh"
  unset _MK_CHEZMOI_LOADED
  _MK_CHEZMOI_STAGING_DIR=""
  _MK_CHEZMOI_TMP_CONFIG_DIR=""

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run

  # blueprints::dir and modules::dir are collaborators; stub them so tests
  # control the directory layout without the fetch lifecycle.
  STUB_OUTPUT="$BATS_TEST_TMPDIR/blueprints" mktest::stub_function blueprints::dir
  STUB_OUTPUT="$BATS_TEST_TMPDIR/mods" mktest::stub_function modules::dir
  mkdir -p "$BATS_TEST_TMPDIR/blueprints" "$BATS_TEST_TMPDIR/mods"
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  chezmoi::install() { echo "original"; }
  _MK_CHEZMOI_LOADED=1
  source "$MACHINEKIT_DIR/lib/modules/chezmoi.sh"
  [ "$(chezmoi::install)" = "original" ]
}

# --- chezmoi::staging_dir ---

@test "staging_dir fails before build_staging is called" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! chezmoi::staging_dir
  MATCH="before.*build_staging" mktest::assert_stub_called lifecycle::fail
}

# --- chezmoi::build_staging ---

@test "build_staging prepares the staging dir then layers module templates and blueprint dotfiles" {
  mktest::stub_function chezmoi::_prepare_staging_dir
  STUB_OUTPUT=$'git\nmise' mktest::stub_function context::get_array "modules.active"
  mktest::stub_function chezmoi::_layer_dir
  chezmoi::build_staging
  mktest::assert_stub_called chezmoi::_prepare_staging_dir
  mktest::assert_stub_called chezmoi::_layer_dir "$BATS_TEST_TMPDIR/mods/git/templates" "git templates"
  mktest::assert_stub_called chezmoi::_layer_dir "$BATS_TEST_TMPDIR/mods/mise/templates" "mise templates"
  mktest::assert_stub_called chezmoi::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/dotfiles" "blueprint common/dotfiles"
}

@test "build_staging layers only the blueprint dotfiles when no modules are active" {
  mktest::stub_function chezmoi::_prepare_staging_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  mktest::stub_function chezmoi::_layer_dir
  chezmoi::build_staging
  TIMES=1 mktest::assert_stub_called chezmoi::_layer_dir
  mktest::assert_stub_called chezmoi::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/dotfiles" "blueprint common/dotfiles"
}

# --- chezmoi::_prepare_staging_dir ---

@test "_prepare_staging_dir in dry-run creates a temp dir and registers cleanup" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  chezmoi::_prepare_staging_dir
  [ -d "$_MK_CHEZMOI_STAGING_DIR" ]
  mktest::assert_stub_called lifecycle::register_cleanup "chezmoi::cleanup_staging"
}

@test "_prepare_staging_dir in real mode creates a persistent dir under HOME and does not register cleanup" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  chezmoi::_prepare_staging_dir
  [ "$_MK_CHEZMOI_STAGING_DIR" = "$HOME/.local/share/machinekit/chezmoi-staging" ]
  [ -d "$_MK_CHEZMOI_STAGING_DIR" ]
  mktest::assert_stub_not_called lifecycle::register_cleanup
}

# --- chezmoi::_layer_dir ---

@test "_layer_dir copies the source contents into the staging dir" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'hello\n' > "$src/dotfile.txt"
  chezmoi::_layer_dir "$src" "test layer"
  [ -f "$_MK_CHEZMOI_STAGING_DIR/dotfile.txt" ]
}

@test "_layer_dir is a no-op when the source dir does not exist" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  chezmoi::_layer_dir "$BATS_TEST_TMPDIR/nonexistent" "absent layer"
  [ -z "$(ls -A "$_MK_CHEZMOI_STAGING_DIR")" ]
}

@test "_layer_dir overwrites an existing same-path file in the staging dir" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  printf 'old\n' > "$_MK_CHEZMOI_STAGING_DIR/config.txt"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'new\n' > "$src/config.txt"
  chezmoi::_layer_dir "$src" "override layer"
  [ "$(cat "$_MK_CHEZMOI_STAGING_DIR/config.txt")" = "new" ]
}

# --- chezmoi::cleanup_staging ---

@test "cleanup_staging removes the staging dir" {
  _MK_CHEZMOI_STAGING_DIR=$(mktemp -d)
  local staging="$_MK_CHEZMOI_STAGING_DIR"
  chezmoi::cleanup_staging
  [ ! -d "$staging" ]
}

# --- chezmoi::cleanup_tmp_config ---

@test "cleanup_tmp_config is a no-op when no tmp config dir is set" {
  _MK_CHEZMOI_TMP_CONFIG_DIR=""
  chezmoi::cleanup_tmp_config
}

@test "cleanup_tmp_config removes the tmp config dir" {
  local d="$BATS_TEST_TMPDIR/tmp-cfg"
  mkdir "$d"
  _MK_CHEZMOI_TMP_CONFIG_DIR="$d"
  chezmoi::cleanup_tmp_config
  [ ! -d "$d" ]
}

# --- chezmoi::write_config ---

@test "write_config fails when age.key_path is not in context" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  STUB_RETURN=1 mktest::stub_function context::get "age.key_path"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! chezmoi::write_config "$BATS_TEST_TMPDIR/out.toml"
  MATCH="age.key_path" mktest::assert_stub_called lifecycle::fail
}

@test "write_config fails with a clear error when config generation fails" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  local key_path="$BATS_TEST_TMPDIR/age/key.txt"
  STUB_OUTPUT="$key_path" mktest::stub_function context::get "age.key_path"
  STUB_RETURN=1 mktest::stub_function context::json
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! chezmoi::write_config "$BATS_TEST_TMPDIR/chezmoi.toml"
  MATCH="Failed" mktest::assert_stub_called lifecycle::fail
}

@test "write_config writes a config file containing the source dir and age key" {
  _MK_CHEZMOI_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  local key_path="$BATS_TEST_TMPDIR/age/key.txt"
  STUB_OUTPUT="$key_path" mktest::stub_function context::get "age.key_path"
  STUB_OUTPUT="{}" mktest::stub_function context::json
  local staging="$_MK_CHEZMOI_STAGING_DIR"
  local out="$BATS_TEST_TMPDIR/chezmoi.toml"
  chezmoi::write_config "$out"
  [ -f "$out" ]
  [ "$(dasel -i toml 'age.identity' < "$out")" = "'$key_path'" ]
  [ "$(dasel -i toml 'sourceDir' < "$out")" = "'$staging'" ]
}

# --- chezmoi::_diff ---

@test "_diff when chezmoi is not installed reports the would-apply source dir and skips write_config" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/staging" mktest::stub_function chezmoi::staging_dir
  STUB_RETURN=1 mktest::stub_function input::command_exists "chezmoi"
  mktest::stub_function logging::dry_run
  mktest::stub_function chezmoi::write_config
  chezmoi::_diff
  MATCH="$BATS_TEST_TMPDIR/staging" mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called chezmoi::write_config
}

@test "_diff non-interactive writes config and delegates to _show_plain_diff" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/staging" mktest::stub_function chezmoi::staging_dir
  mktest::stub_function input::command_exists "chezmoi"
  mktest::stub_function lifecycle::register_cleanup
  mktest::stub_function chezmoi::write_config
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function chezmoi::_show_plain_diff
  chezmoi::_diff
  mktest::assert_stub_called chezmoi::write_config
  MATCH="$BATS_TEST_TMPDIR/staging" mktest::assert_stub_called chezmoi::_show_plain_diff
}

@test "_diff interactive writes config and delegates to _show_interactive_diff" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/staging" mktest::stub_function chezmoi::staging_dir
  mktest::stub_function input::command_exists "chezmoi"
  mktest::stub_function lifecycle::register_cleanup
  mktest::stub_function chezmoi::write_config
  mktest::stub_function input::is_interactive
  mktest::stub_function chezmoi::_show_interactive_diff
  chezmoi::_diff
  mktest::assert_stub_called chezmoi::write_config
  MATCH="$BATS_TEST_TMPDIR/staging" mktest::assert_stub_called chezmoi::_show_interactive_diff
}

# --- chezmoi::_show_plain_diff ---

@test "_show_plain_diff runs chezmoi diff with --no-pager" {
  mktest::stub_function chezmoi
  chezmoi::_show_plain_diff "$BATS_TEST_TMPDIR/staging" "$BATS_TEST_TMPDIR/cfg.toml"
  MATCH="--no-pager" mktest::assert_stub_called chezmoi
}

# --- chezmoi::_show_interactive_diff ---

@test "_show_interactive_diff prompts then pipes the diff through less -R" {
  printf 'x' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  mktest::stub_function chezmoi
  mktest::stub_function less
  chezmoi::_show_interactive_diff "$BATS_TEST_TMPDIR/staging" "$BATS_TEST_TMPDIR/cfg.toml"
  MATCH="-R" mktest::assert_stub_called less
}

# --- chezmoi::install ---

@test "install in dry-run delegates to _diff" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function chezmoi::build_staging
  mktest::stub_function chezmoi::_diff
  chezmoi::install
  mktest::assert_stub_called chezmoi::_diff
}

@test "install in real mode runs chezmoi apply without --force when interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function chezmoi::build_staging
  STUB_OUTPUT="$BATS_TEST_TMPDIR/staging" mktest::stub_function chezmoi::staging_dir
  mktest::stub_function chezmoi::write_config
  mktest::stub_function input::is_interactive
  mktest::stub_function chezmoi
  chezmoi::install
  MATCH="apply" mktest::assert_stub_called chezmoi
  MATCH="--force" mktest::assert_stub_not_called chezmoi
}

@test "install in real mode runs chezmoi apply with --force when non-interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function chezmoi::build_staging
  STUB_OUTPUT="$BATS_TEST_TMPDIR/staging" mktest::stub_function chezmoi::staging_dir
  mktest::stub_function chezmoi::write_config
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function chezmoi
  chezmoi::install
  MATCH="--force" mktest::assert_stub_called chezmoi
}
