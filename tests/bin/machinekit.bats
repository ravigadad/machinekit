#!/usr/bin/env bats
# Tests for bin/machinekit (the top-level dispatcher)

load "${BATS_TEST_DIRNAME}/../test_helper"

# All tests here are subprocess-based: the dispatcher is pure routing logic with
# no sourceable unit to stub.

# The apply/generate dispatch resolves a bash that meets the floor before exec'ing
# the impl. Point MACHINEKIT_BASH at a known-good bash so the dispatch can never
# trigger a real Homebrew install; skip if this environment has no qualifying bash
# (then there's nothing the impl could run under anyway).
require_modern_bash() {
  if [ "${BASH_VERSINFO[0]}" -gt 5 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
    return 0
  fi
  skip "no bash >= 5.3 available to run the impl"
}

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
  require_modern_bash
  MACHINEKIT_BASH="$BASH" run "$MACHINEKIT_DIR/bin/machinekit" apply --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit apply"* ]]
}

@test "generate --help dispatches to machinekit-generate and exits 0" {
  require_modern_bash
  MACHINEKIT_BASH="$BASH" run "$MACHINEKIT_DIR/bin/machinekit" generate --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: machinekit generate"* ]]
}
