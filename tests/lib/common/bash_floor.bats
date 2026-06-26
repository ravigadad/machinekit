#!/usr/bin/env bats
# Tests for lib/common/bash_floor.sh — the single source of machinekit's minimum
# bash version, its predicate, and the entry guard. Pure-3.2.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/common/bash_floor.sh
  source "$MACHINEKIT_DIR/lib/common/bash_floor.sh"
}

# --- bash_floor::meets ---

@test "meets accepts the floor exactly and anything above" {
  bash_floor::meets 5 3
  bash_floor::meets 5 4
  bash_floor::meets 6 0
}

@test "meets rejects anything below the floor" {
  run ! bash_floor::meets 5 2
  run ! bash_floor::meets 4 4
}

# --- bash_floor::guard ---

@test "guard passes silently under a bash that meets the floor" {
  # The suite runs under brew bash >= 5.3, so the guard is a no-op here.
  bash_floor::guard
}

@test "guard exits with a clear message under a bash below the floor" {
  run /bin/bash -c "source '$MACHINEKIT_DIR/lib/common/bash_floor.sh'; bash_floor::guard"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}
