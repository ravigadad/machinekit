#!/usr/bin/env bats
# Tests for libexec/machinekit-ensure-on-path — the installer-invoked impl that
# links the machinekit command into ~/.local/bin and wires it onto PATH. main is
# sourced and unit-tested with path::ensure_on_path stubbed; the flag/behaviour
# integration and the bash-floor guard (the one collaborator that can't be
# stubbed, since it runs in the load-time prologue) are exercised as subprocesses.

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  # Controlled HOME so sourcing — or any link/rc edit — can never touch the real
  # machine, and the subprocesses below inherit it.
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export HOME
  # shellcheck source=../../libexec/machinekit-ensure-on-path
  source "$MACHINEKIT_DIR/libexec/machinekit-ensure-on-path"
}

# --- BASH_SOURCE guard ---

@test "sourcing does not auto-execute main" {
  # Sourced in setup. If the guard were missing, main would have run
  # path::ensure_on_path and linked the command into ~/.local/bin during setup.
  [ ! -e "$HOME/.local/bin/machinekit" ]
}

# --- main (sourced) ---

@test "main links machinekit on PATH (modify_path=1) by default" {
  mktest::stub_function path::ensure_on_path
  main
  mktest::assert_stub_called path::ensure_on_path 1
}

@test "main passes modify_path=0 for --no-modify-path" {
  mktest::stub_function path::ensure_on_path
  main --no-modify-path
  mktest::assert_stub_called path::ensure_on_path 0
}

# --- bash-floor guard (subprocess; the one collaborator we can't stub) ---

@test "rejects a direct call under a bash below the floor" {
  run /bin/bash "$MACHINEKIT_DIR/libexec/machinekit-ensure-on-path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}

# --- flag + behaviour integration (subprocess) ---

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/libexec/machinekit-ensure-on-path" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit-ensure-on-path"* ]]
}

@test "rejects an unknown flag" {
  run "$MACHINEKIT_DIR/libexec/machinekit-ensure-on-path" --frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}
