#!/usr/bin/env bats
# Tests for lib/machinekit/secrets/render.sh — the `list` view.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/secrets/render.sh
  source "$MACHINEKIT_DIR/lib/machinekit/secrets/render.sh"
  mktest::stub_function logging::info
}

# --- secrets::render ---

@test "render reports nothing to show when no secrets are needed or present" {
  STUB_OUTPUT="" mktest::stub_function secrets::inventory
  STUB_OUTPUT="" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::render::_table
  mktest::stub_function secrets::render::_orphans
  secrets::render
  mktest::assert_stub_not_called secrets::render::_table
  MATCH="No pool secrets" mktest::assert_stub_called logging::info
}

@test "render delegates to the table when secrets are declared" {
  STUB_OUTPUT=$'secrets/x.age\ttrue\tfalse\tprovided' mktest::stub_function secrets::inventory
  STUB_OUTPUT="" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::render::_table
  mktest::stub_function secrets::render::_orphans
  secrets::render
  mktest::assert_stub_called secrets::render::_table $'secrets/x.age\ttrue\tfalse\tprovided'
  mktest::assert_stub_not_called secrets::render::_orphans
}

@test "render lists orphans separately when the pool has unrecognized secrets" {
  STUB_OUTPUT="" mktest::stub_function secrets::inventory
  STUB_OUTPUT="secrets/stray.age" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::render::_table
  mktest::stub_function secrets::render::_orphans
  secrets::render
  mktest::assert_stub_called secrets::render::_orphans "secrets/stray.age"
  mktest::assert_stub_not_called secrets::render::_table
}

# --- secrets::render::_table ---

@test "_table prints a blank line, a header, and yes/no columns from the booleans" {
  STUB_RETURN=1 mktest::stub_function secrets::render::_color_enabled   # color off: assert layout, not ANSI
  run secrets::render::_table $'secrets/a.age\ttrue\tfalse\tprovided\nsecrets/bb.age\ttrue\ttrue\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == $'\n'* ]]   # blank line above the table
  [[ "$output" == *"SECRET"*"IN POOL"*"REQUIRED"*"GENERATE IF MISSING"* ]]
  # provided + required + not-generatable -> yes / yes / no
  [[ "${lines[1]}" == "secrets/a.age"*" yes "*" yes "*" no"* ]]
  # missing + required + generatable -> no / yes / yes
  [[ "${lines[2]}" == "secrets/bb.age"*" no "*" yes "*" yes"* ]]
}

@test "_table colors each row by its disposition when color is enabled" {
  mktest::stub_function secrets::render::_color_enabled  # default STUB_RETURN 0 = enabled
  run secrets::render::_table $'secrets/p.age\ttrue\tfalse\tprovided\nsecrets/g.age\ttrue\ttrue\tmissing\nsecrets/b.age\ttrue\tfalse\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32msecrets/p.age'* ]]   # in pool -> green
  [[ "$output" == *$'\033[33msecrets/g.age'* ]]   # absent, generatable -> yellow
  [[ "$output" == *$'\033[31msecrets/b.age'* ]]   # absent, required, not generatable -> red blocker
}

@test "_table emits no color when color is disabled" {
  STUB_RETURN=1 mktest::stub_function secrets::render::_color_enabled
  run secrets::render::_table $'secrets/a.age\ttrue\tfalse\tprovided'
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

# --- secrets::render::_orphans ---

@test "_orphans lists each stray under a heading" {
  run secrets::render::_orphans $'secrets/stray1.age\nsecrets/stray2.age'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unrecognized secrets in the pool"* ]]
  [[ "$output" == *"  secrets/stray1.age"* ]]
  [[ "$output" == *"  secrets/stray2.age"* ]]
}

# --- secrets::render::_color_enabled ---

@test "_color_enabled is true on a tty with NO_COLOR unset" {
  mktest::stub_function input::stdout_is_tty   # tty present
  NO_COLOR="" run secrets::render::_color_enabled
  [ "$status" -eq 0 ]
}

@test "_color_enabled is false when NO_COLOR is set even on a tty" {
  mktest::stub_function input::stdout_is_tty   # tty present
  NO_COLOR=1 run secrets::render::_color_enabled
  [ "$status" -ne 0 ]
}

@test "_color_enabled is false when stdout is not a tty" {
  STUB_RETURN=1 mktest::stub_function input::stdout_is_tty
  NO_COLOR="" run secrets::render::_color_enabled
  [ "$status" -ne 0 ]
}
