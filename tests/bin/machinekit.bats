#!/usr/bin/env bats
# Tests for bin/machinekit (the top-level dispatcher)

load "${BATS_TEST_DIRNAME}/../test_helper"

# All tests here are subprocess-based: the dispatcher is pure routing logic with
# no sourceable unit to stub.

@test "no arguments exits 1" {
  run "$MACHINEKIT_DIR/bin/machinekit"
  [ "$status" -eq 1 ]
}

@test "--help exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/bin/machinekit" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subcommands:"* ]]
}

@test "help subcommand exits 0 and prints usage" {
  run "$MACHINEKIT_DIR/bin/machinekit" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subcommands:"* ]]
}

@test "--version prints the version and exits 0" {
  run "$MACHINEKIT_DIR/bin/machinekit" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$MACHINEKIT_DIR/VERSION")" ]
}

@test "version subcommand prints the version and exits 0" {
  run "$MACHINEKIT_DIR/bin/machinekit" version
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$MACHINEKIT_DIR/VERSION")" ]
}

@test "unknown subcommand exits 1" {
  run "$MACHINEKIT_DIR/bin/machinekit" frobnicate
  [ "$status" -eq 1 ]
}

@test "apply --help dispatches to machinekit-apply and exits 0" {
  run "$MACHINEKIT_DIR/bin/machinekit" apply --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit apply"* ]]
}

@test "generate --help dispatches to machinekit-generate and exits 0" {
  run "$MACHINEKIT_DIR/bin/machinekit" generate --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit generate"* ]]
}
