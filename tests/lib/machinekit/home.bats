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

  STUB_OUTPUT="$BATS_TEST_TMPDIR/blueprints" mktest::stub_function blueprints::dir
  STUB_OUTPUT="$BATS_TEST_TMPDIR/mods" mktest::stub_function modules::dir
  mkdir -p "$BATS_TEST_TMPDIR/blueprints" "$BATS_TEST_TMPDIR/mods"
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::sync() { echo "original"; }
  _MK_HOME_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home.sh"
  [ "$(home::sync)" = "original" ]
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
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
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
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function home::_layer_dir
  home::build_staging
  TIMES=1 mktest::assert_stub_called home::_layer_dir
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

@test "build_staging layers machine_type home after blueprint common/home when machine_type is set" {
  mktest::stub_function home::_prepare_staging_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  mktest::stub_function home::_layer_dir
  home::build_staging
  TIMES=2 mktest::assert_stub_called home::_layer_dir
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
  mktest::assert_stub_called home::_layer_dir "$BATS_TEST_TMPDIR/blueprints/machine_types/laptop/home" "blueprint machine_types/laptop/home"
}

@test "build_staging skips machine_type home layer when machine_type is not set" {
  mktest::stub_function home::_prepare_staging_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
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
  mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf '.zshrc.local\n' > "$_MK_HOME_STAGING_DIR/.mkignore"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/.mkignore" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_not_called home::_reconcile_file
}

@test "_apply_file skips files listed in .mkignore" {
  mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf '.zshrc.local\n' > "$_MK_HOME_STAGING_DIR/.mkignore"
  printf 'local settings\n' > "$_MK_HOME_STAGING_DIR/dot_zshrc.local"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_zshrc.local" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_not_called home::_reconcile_file
}

@test "_apply_file does not skip a file absent from .mkignore" {
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'content\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'other_file\n' > "$_MK_HOME_STAGING_DIR/.mkignore"
  printf 'content\n' > "$_MK_HOME_STAGING_DIR/dot_zshrc"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_zshrc" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called home::_reconcile_file
}

@test "_apply_file calls _reconcile_file with rendered output and decoded destination" {
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'rendered content\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'staging\n' > "$_MK_HOME_STAGING_DIR/dot_zshrc"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_zshrc" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called home::_reconcile_file "$render_out" "$HOME/.zshrc" ".zshrc" "0"
}

@test "_apply_file calls _render_file with src, is_template flag, and ctx_file" {
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'rendered content\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'template\n' > "$_MK_HOME_STAGING_DIR/dot_gitconfig.tmpl"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$_MK_HOME_STAGING_DIR/dot_gitconfig.tmpl" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called home::_render_file \
    "$_MK_HOME_STAGING_DIR/dot_gitconfig.tmpl" "1" "$ctx_file"
}

@test "_apply_file passes is_private=1 to _reconcile_file for a file with private_ in its path" {
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'Host *\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  local ssh_staging="$_MK_HOME_STAGING_DIR/private_dot_ssh"
  mkdir -p "$ssh_staging"
  printf 'Host *\n' > "$ssh_staging/private_config"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$ssh_staging/private_config" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called home::_reconcile_file "$render_out" "$HOME/.ssh/config" ".ssh/config" "1"
}

@test "_apply_file calls _apply_parent_perms with src_rel and dest_path" {
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'Host *\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::_reconcile_file
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  local ssh_staging="$_MK_HOME_STAGING_DIR/private_dot_ssh"
  mkdir -p "$ssh_staging"
  printf 'Host *\n' > "$ssh_staging/private_config"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  home::_apply_file "$ssh_staging/private_config" "$_MK_HOME_STAGING_DIR" "$ctx_file"
  mktest::assert_stub_called home::_apply_parent_perms \
    "private_dot_ssh/private_config" "$HOME/.ssh/config"
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
  home::_apply_parent_perms "dot_zshrc" "$BATS_TEST_TMPDIR/home/.zshrc"
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

# --- home::_render_file ---

@test "_render_file copies a non-template file to a temp file and returns the path" {
  local src="$BATS_TEST_TMPDIR/source.txt"
  printf 'hello\n' > "$src"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  result=$(home::_render_file "$src" "0" "$ctx_file")
  [ -f "$result" ]
  [ "$(cat "$result")" = "hello" ]
}

@test "_render_file runs gomplate for a template file and returns the path" {
  local src="$BATS_TEST_TMPDIR/source.tmpl"
  printf 'template\n' > "$src"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  mktest::stub_function gomplate
  result=$(home::_render_file "$src" "1" "$ctx_file")
  [ -f "$result" ]
  mktest::assert_stub_called gomplate
}

@test "_render_file passes the context file to gomplate" {
  local src="$BATS_TEST_TMPDIR/source.tmpl"
  printf 'template\n' > "$src"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  printf '{}' > "$ctx_file"
  mktest::stub_function gomplate
  home::_render_file "$src" "1" "$ctx_file"
  MATCH="ctx.json" mktest::assert_stub_called gomplate
}

# --- home::_reconcile_file ---

@test "_reconcile_file writes and logs applied for a new file" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  printf 'content\n' > "$resolved"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
  mktest::assert_stub_not_called home::_conflict_action
}

@test "_reconcile_file removes resolved and logs unchanged when dest content is identical" {
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

@test "_reconcile_file calls _conflict_action and writes when dest content differs" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_conflict_action ".zshrc" "$resolved" "$dest"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
}

@test "_reconcile_file does not write when _conflict_action returns skip" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  STUB_RETURN=1 mktest::stub_function home::_conflict_action
  mktest::stub_function home::_write_file
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_not_called home::_write_file
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

# --- home::_read_conflict_choice ---

@test "_read_conflict_choice reads one character from MACHINEKIT_TTY" {
  printf 'o' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(home::_read_conflict_choice)
  [ "$result" = "o" ]
}

# --- home::_show_conflict_diff ---

@test "_show_conflict_diff calls git diff and pipes output to less when files differ" {
  local resolved="$BATS_TEST_TMPDIR/new.txt"
  local dest="$BATS_TEST_TMPDIR/old.txt"
  printf 'new\n' > "$resolved"
  printf 'old\n' > "$dest"
  STUB_OUTPUT="diff content" mktest::stub_function git
  mktest::stub_function less
  home::_show_conflict_diff "$resolved" "$dest"
  MATCH="--no-index" mktest::assert_stub_called git
  mktest::assert_stub_called less
}

@test "_show_conflict_diff does not open less when diff is empty" {
  local resolved="$BATS_TEST_TMPDIR/same.txt"
  local dest="$BATS_TEST_TMPDIR/same2.txt"
  printf 'same\n' > "$resolved"
  printf 'same\n' > "$dest"
  mktest::stub_function git
  mktest::stub_function less
  home::_show_conflict_diff "$resolved" "$dest"
  mktest::assert_stub_not_called less
}

# --- home::_render_to_outdir ---

@test "_render_to_outdir delegates to _render_file and writes output to the out_dir" {
  local staging="$BATS_TEST_TMPDIR/staging"
  local out_dir="$BATS_TEST_TMPDIR/out"
  local ctx_file="$BATS_TEST_TMPDIR/ctx.json"
  mkdir -p "$staging" "$out_dir"
  printf 'content\n' > "$staging/dot_zshrc"
  printf '{}' > "$ctx_file"
  local render_out="$BATS_TEST_TMPDIR/rendered"
  printf 'rendered\n' > "$render_out"
  STUB_OUTPUT="$render_out" mktest::stub_function home::_render_file
  home::_render_to_outdir "$staging/dot_zshrc" "$staging" "$ctx_file" "$out_dir"
  mktest::assert_stub_called home::_render_file
  [ -f "$out_dir/.zshrc" ]
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

# --- home::sync ---

@test "sync in dry-run delegates to _diff" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function home::build_staging
  mktest::stub_function home::_diff
  home::sync
  mktest::assert_stub_called home::_diff
}

@test "sync in real mode calls build_staging then _apply" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function home::build_staging
  mktest::stub_function home::_apply
  home::sync
  mktest::assert_stub_called home::build_staging
  mktest::assert_stub_called home::_apply
}
