#!/usr/bin/env bats
# Tests for lib/machinekit/home.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/home/staging.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home/staging.sh"
  unset _MK_HOME_STAGING_LOADED
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

  STUB_OUTPUT="$BATS_TEST_TMPDIR/blueprints" mktest::stub_function blueprints::dir
  STUB_OUTPUT="$BATS_TEST_TMPDIR/mods" mktest::stub_function modules::dir
  mkdir -p "$BATS_TEST_TMPDIR/blueprints" "$BATS_TEST_TMPDIR/mods"
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::staging::dir() { echo "original"; }
  _MK_HOME_STAGING_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home/staging.sh"
  [ "$(home::staging::dir)" = "original" ]
}

# --- home::staging::dir ---

@test "dir fails before build is called" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::staging::dir
  MATCH="before.*staging::build" mktest::assert_stub_called lifecycle::fail
}

@test "dir returns the staging dir path when set" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  result=$(home::staging::dir)
  [ "$result" = "$BATS_TEST_TMPDIR/staging" ]
}

# --- home::staging::build ---

@test "build prepares the staging dir then layers module templates and blueprint home" {
  mktest::stub_function home::staging::_prepare_dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function context::get_array "modules.active"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function home::staging::_layer_dir
  home::staging::build
  TIMES=3 mktest::assert_stub_called home::staging::_layer_dir
  mktest::assert_stub_called_in_order home::staging::_prepare_dir
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/mods/foo/templates" "foo templates"
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/mods/bar/templates" "bar templates"
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

@test "build layers only the blueprint home when no modules are active" {
  mktest::stub_function home::staging::_prepare_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function home::staging::_layer_dir
  home::staging::build
  TIMES=1 mktest::assert_stub_called home::staging::_layer_dir
  mktest::assert_stub_called_in_order home::staging::_prepare_dir
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

@test "build layers machine_type home after blueprint common/home when machine_type is set" {
  mktest::stub_function home::staging::_prepare_dir
  STUB_RETURN=1 mktest::stub_function context::get_array "modules.active"
  STUB_OUTPUT="laptop" mktest::stub_function context::get "machine_type"
  mktest::stub_function home::staging::_layer_dir
  home::staging::build
  TIMES=2 mktest::assert_stub_called home::staging::_layer_dir
  mktest::assert_stub_called_in_order home::staging::_prepare_dir
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/blueprints/machine_types/laptop/home" "blueprint machine_types/laptop/home"
}

@test "build skips machine_type home layer when machine_type is not set" {
  mktest::stub_function home::staging::_prepare_dir
  STUB_OUTPUT="foo" mktest::stub_function context::get_array "modules.active"
  STUB_RETURN=1 mktest::stub_function context::get "machine_type"
  mktest::stub_function home::staging::_layer_dir
  home::staging::build
  TIMES=2 mktest::assert_stub_called home::staging::_layer_dir
  mktest::assert_stub_called_in_order home::staging::_prepare_dir
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/mods/foo/templates" "foo templates"
  mktest::assert_stub_called_in_order home::staging::_layer_dir "$BATS_TEST_TMPDIR/blueprints/common/home" "blueprint common/home"
}

# --- home::staging::cleanup ---

@test "cleanup removes the staging dir" {
  _MK_HOME_STAGING_DIR=$(mktemp -d)
  local staging="$_MK_HOME_STAGING_DIR"
  home::staging::cleanup
  [ ! -d "$staging" ]
}

# --- home::staging::_prepare_dir ---

@test "_prepare_dir in dry-run creates a temp dir and registers cleanup" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  home::staging::_prepare_dir
  [ -d "$_MK_HOME_STAGING_DIR" ]
  mktest::assert_stub_called lifecycle::register_cleanup "home::staging::cleanup"
}

@test "_prepare_dir in real mode creates a persistent dir under HOME and does not register cleanup" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function lifecycle::register_cleanup
  home::staging::_prepare_dir
  [ "$_MK_HOME_STAGING_DIR" = "$HOME/.local/share/machinekit/staging" ]
  [ -d "$_MK_HOME_STAGING_DIR" ]
  mktest::assert_stub_not_called lifecycle::register_cleanup
}

# --- home::staging::_layer_dir ---

@test "_layer_dir copies the source contents into the staging dir" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'hello\n' > "$src/dotfile.txt"
  home::staging::_layer_dir "$src" "test layer"
  [ -f "$_MK_HOME_STAGING_DIR/dotfile.txt" ]
}

@test "_layer_dir is a no-op when the source dir does not exist" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  home::staging::_layer_dir "$BATS_TEST_TMPDIR/nonexistent" "absent layer"
  [ -z "$(ls -A "$_MK_HOME_STAGING_DIR")" ]
}

@test "_layer_dir overwrites an existing same-path file in the staging dir" {
  _MK_HOME_STAGING_DIR="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$_MK_HOME_STAGING_DIR"
  printf 'old\n' > "$_MK_HOME_STAGING_DIR/config.txt"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'new\n' > "$src/config.txt"
  home::staging::_layer_dir "$src" "override layer"
  [ "$(cat "$_MK_HOME_STAGING_DIR/config.txt")" = "new" ]
}
