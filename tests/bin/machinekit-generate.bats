#!/usr/bin/env bats
# Tests for bin/machinekit-generate

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  set --  # prevent the top-level flag parser from consuming bats's internal $@
  # shellcheck source=../../bin/machinekit-generate
  source "$MACHINEKIT_DIR/bin/machinekit-generate"

  mktest::stub_function logging::step
  mktest::stub_function logging::success
  mktest::stub_function logging::info
}

# --- BASH_SOURCE guard ---

@test "sourcing does not auto-execute main" {
  # If the guard were missing, sourcing would call main() → resolve_path("") →
  # lifecycle::fail → exit 1, failing setup() before reaching this assertion.
  true
}

# --- main (sourced) ---

@test "main calls the full pipeline" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/target" mktest::stub_function generate::resolve_path
  mktest::stub_function generate::copy_template
  mktest::stub_function generate::print_next_steps
  main
  mktest::assert_stub_called generate::resolve_path
  mktest::assert_stub_called generate::copy_template
  mktest::assert_stub_called generate::print_next_steps
}

@test "main passes the resolved path to copy_template and print_next_steps" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/target" mktest::stub_function generate::resolve_path
  mktest::stub_function generate::copy_template
  mktest::stub_function generate::print_next_steps
  main
  mktest::assert_stub_called generate::copy_template "$BATS_TEST_TMPDIR/target"
  mktest::assert_stub_called generate::print_next_steps "$BATS_TEST_TMPDIR/target"
}

# --- generate::resolve_path ---

@test "resolve_path returns an absolute path unchanged" {
  local result
  result=$(generate::resolve_path "$BATS_TEST_TMPDIR/newdir")
  [ "$result" = "$BATS_TEST_TMPDIR/newdir" ]
}

@test "resolve_path resolves a relative path against the current directory" {
  local result
  result=$(cd "$BATS_TEST_TMPDIR" && generate::resolve_path "newdir")
  [ "$result" = "$BATS_TEST_TMPDIR/newdir" ]
}

@test "resolve_path fails when path is empty" {
  run generate::resolve_path ""
  [ "$status" -ne 0 ]
}

@test "resolve_path fails when target already exists" {
  mkdir "$BATS_TEST_TMPDIR/existing"
  run generate::resolve_path "$BATS_TEST_TMPDIR/existing"
  [ "$status" -ne 0 ]
}

@test "resolve_path fails when name contains whitespace" {
  run generate::resolve_path "$BATS_TEST_TMPDIR/my blueprints"
  [ "$status" -ne 0 ]
}

# --- generate::copy_template ---

@test "copy_template copies blueprint template files to the target" {
  generate::copy_template "$BATS_TEST_TMPDIR/blueprints"
  [ -f "$BATS_TEST_TMPDIR/blueprints/common/machinekit.toml" ]
  [ -f "$BATS_TEST_TMPDIR/blueprints/common/Brewfile" ]
  [ -f "$BATS_TEST_TMPDIR/blueprints/common/home/.mkignore" ]
  [ -f "$BATS_TEST_TMPDIR/blueprints/machine_types/README.md" ]
}

@test "copy_template creates the target directory if it does not exist" {
  generate::copy_template "$BATS_TEST_TMPDIR/newdir"
  [ -d "$BATS_TEST_TMPDIR/newdir" ]
}

# --- generate::print_next_steps ---

@test "print_next_steps includes the target path in its output" {
  generate::print_next_steps "/my/target"
  MATCH="/my/target" mktest::assert_stub_called logging::info
}

# --- CLI behavior (subprocess) ---

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/bin/machinekit-generate" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit generate"* ]]
}

@test "--version prints the version and exits 0" {
  run "$MACHINEKIT_DIR/bin/machinekit-generate" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$MACHINEKIT_DIR/VERSION")" ]
}

@test "unknown flag exits 1" {
  run "$MACHINEKIT_DIR/bin/machinekit-generate" --no-such-flag
  [ "$status" -eq 1 ]
}
