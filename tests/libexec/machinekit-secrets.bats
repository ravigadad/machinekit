#!/usr/bin/env bats
# Tests for libexec/machinekit-secrets — the thin controller: flag parsing and
# dispatch. The orchestration and logic are tested under tests/lib/machinekit/secrets/.

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  set --  # prevent the top-level flag parser from consuming bats's internal $@
  # shellcheck source=../../libexec/machinekit-secrets
  source "$MACHINEKIT_DIR/libexec/machinekit-secrets"
  mktest::stub_function secrets::cli::dispatch
}

# --- BASH_SOURCE guard ---

@test "sourcing does not auto-execute main" {
  # The guard kept main() from running during source in setup; had it run,
  # dispatch (stubbed) would show a call here.
  mktest::assert_stub_not_called secrets::cli::dispatch
}

# --- main ---

@test "main forwards the parsed command, target, and from-file to dispatch" {
  COMMAND=put
  OPT_TARGET="secrets/x.age"
  OPT_FROM_FILE="/tmp/val"
  main
  mktest::assert_stub_called secrets::cli::dispatch put "secrets/x.age" "/tmp/val"
}

# --- CLI behavior (subprocess) ---

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/libexec/machinekit-secrets" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit secrets"* ]]
}

@test "--version prints the version and exits 0" {
  run "$MACHINEKIT_DIR/libexec/machinekit-secrets" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$MACHINEKIT_DIR/VERSION")" ]
}

@test "unknown flag exits 1" {
  run "$MACHINEKIT_DIR/libexec/machinekit-secrets" --no-such-flag
  [ "$status" -eq 1 ]
}

@test "a second positional argument is rejected" {
  run "$MACHINEKIT_DIR/libexec/machinekit-secrets" put one two
  [ "$status" -eq 1 ]
}

@test "run directly under a bash below the floor fails cleanly" {
  run /bin/bash "$MACHINEKIT_DIR/libexec/machinekit-secrets" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}
