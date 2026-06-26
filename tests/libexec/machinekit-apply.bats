#!/usr/bin/env bats
# Tests for libexec/machinekit-apply

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  set --  # prevent the top-level flag parser from consuming bats's internal $@
  # shellcheck source=../../libexec/machinekit-apply
  source "$MACHINEKIT_DIR/libexec/machinekit-apply"

  # Stub the entire pipeline — the contract of main() IS the wiring, not the
  # internals of each step.
  mktest::stub_function context::init_storage
  mktest::stub_function lifecycle::acquire_lock
  mktest::stub_function brew::bootstrap
  mktest::stub_function prerequisites::install
  mktest::stub_function context::seed_from_flags
  mktest::stub_function input::detect_mode
  mktest::stub_function sudo::ensure
  mktest::stub_function preflight::run
  mktest::stub_function modules::run_installs
  mktest::stub_function home::sync
  mktest::stub_function modules::run_post_apply
  mktest::stub_function hooks::run_post_apply
  mktest::stub_function postflight::run
  mktest::stub_function logging::step
}

# --- BASH_SOURCE guard ---

@test "sourcing does not auto-execute main" {
  # If the BASH_SOURCE guard is working, none of main()'s pipeline steps should
  # have been called during the source in setup().
  mktest::assert_stub_not_called context::init_storage
}

# --- main ---

@test "main calls the full pipeline in order" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  main
  mktest::assert_stub_called_in_order context::init_storage
  mktest::assert_stub_called_in_order lifecycle::acquire_lock
  mktest::assert_stub_called_in_order brew::bootstrap
  mktest::assert_stub_called_in_order prerequisites::install
  mktest::assert_stub_called_in_order context::seed_from_flags
  mktest::assert_stub_called_in_order input::detect_mode
  mktest::assert_stub_called_in_order sudo::ensure
  mktest::assert_stub_called_in_order preflight::run
  mktest::assert_stub_called_in_order modules::run_installs
  mktest::assert_stub_called_in_order home::sync
  mktest::assert_stub_called_in_order modules::run_post_apply
  mktest::assert_stub_called_in_order hooks::run_post_apply
  mktest::assert_stub_called_in_order postflight::run
}

@test "main logs a DRY RUN banner when in dry-run mode" {
  STUB_RETURN=0 mktest::stub_function input::is_dry_run
  main
  MATCH="DRY RUN" mktest::assert_stub_called logging::step
}

@test "main skips DRY RUN banner when not in dry-run mode" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  main
  MATCH="DRY RUN" mktest::assert_stub_not_called logging::step
}

# --- CLI behavior (subprocess) ---

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/libexec/machinekit-apply" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit apply"* ]]
}

@test "--version prints the version and exits 0" {
  run "$MACHINEKIT_DIR/libexec/machinekit-apply" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$MACHINEKIT_DIR/VERSION")" ]
}

@test "unknown flag exits 1" {
  run "$MACHINEKIT_DIR/libexec/machinekit-apply" --no-such-flag
  [ "$status" -eq 1 ]
}

@test "run directly under a bash below the floor fails cleanly" {
  run /bin/bash "$MACHINEKIT_DIR/libexec/machinekit-apply" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}
