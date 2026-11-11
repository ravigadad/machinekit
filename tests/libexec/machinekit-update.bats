#!/usr/bin/env bats
# Tests for libexec/machinekit-update — moves machinekit's clone to its update
# target, then reruns the installer's steps from the new code. main is sourced
# and unit-tested with its collaborators stubbed; the bash-floor guard and the
# flag handling are exercised as subprocesses.

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  # shellcheck source=../../libexec/machinekit-update
  source "$MACHINEKIT_DIR/libexec/machinekit-update"
}

_mk_test_stub_cascade() {
  mktest::stub_function context::init_storage
  mktest::stub_function lifecycle::acquire_lock
  mktest::stub_function brew::bootstrap
  mktest::stub_function prerequisites::install
  mktest::stub_function context::seed_from_flags
  mktest::stub_function context::load_user_config
}

# --- main (sourced) ---

@test "main prepares the run, updates the clone, then reruns the installer's steps from the new code, on this clone" {
  _mk_test_stub_cascade
  mktest::stub_function framework::update 0
  mktest::stub_function lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh"
  main
  mktest::assert_stub_called_in_order context::init_storage
  mktest::assert_stub_called_in_order lifecycle::acquire_lock
  mktest::assert_stub_called_in_order brew::bootstrap
  mktest::assert_stub_called_in_order prerequisites::install
  mktest::assert_stub_called_in_order context::seed_from_flags
  mktest::assert_stub_called_in_order context::load_user_config
  mktest::assert_stub_called_in_order framework::update 0
  mktest::assert_stub_called_in_order lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh"
}

@test "main with --reset updates past local changes" {
  _mk_test_stub_cascade
  mktest::stub_function framework::update 1
  mktest::stub_function lifecycle::exec
  main --reset
  mktest::assert_stub_called framework::update 1
}

@test "main passes the PATH flags on to the installer's steps" {
  _mk_test_stub_cascade
  mktest::stub_function framework::update 0
  mktest::stub_function lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh" --no-modify-path
  main --no-modify-path
  mktest::assert_stub_called lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh" --no-modify-path
}

@test "main passes --modify-path on to the installer's steps" {
  _mk_test_stub_cascade
  mktest::stub_function framework::update 0
  mktest::stub_function lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh" --modify-path
  main --modify-path
  mktest::assert_stub_called lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 MACHINEKIT_FRAMEWORK_DIR="$MACHINEKIT_DIR" /bin/bash "$MACHINEKIT_DIR/install.sh" --modify-path
}

# --- bash-floor guard (subprocess; the one collaborator we can't stub) ---

@test "run directly under a bash below the floor fails cleanly" {
  mktest::skip_unless_system_bash_below_floor
  run /bin/bash "$MACHINEKIT_DIR/libexec/machinekit-update" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}

# --- flag handling (subprocess) ---

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/libexec/machinekit-update" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit update"* ]]
}

@test "rejects an unknown flag" {
  run "$MACHINEKIT_DIR/libexec/machinekit-update" --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}
