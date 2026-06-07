#!/usr/bin/env bats
# Tests for lib/machinekit/hook-support.sh
#
# Verifies that sourcing hook-support.sh makes all expected library functions
# available. One representative function per sourced library is sufficient —
# the full library's behaviour is covered by its own test file.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/hook-support.sh
  source "$MACHINEKIT_DIR/lib/machinekit/hook-support.sh"
}

@test "sourcing makes logging functions available" {
  declare -f logging::info > /dev/null
}

@test "sourcing makes input functions available" {
  declare -f input::is_dry_run > /dev/null
}

@test "sourcing makes lifecycle functions available" {
  declare -f lifecycle::fail > /dev/null
}

@test "sourcing makes context functions available" {
  declare -f context::get > /dev/null
}

@test "sourcing makes config functions available" {
  declare -f config::get > /dev/null
}
