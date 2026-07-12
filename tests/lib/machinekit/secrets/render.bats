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
  MATCH="No secrets" mktest::assert_stub_called logging::info
}

@test "render delegates to the table when secrets are declared" {
  STUB_OUTPUT=$'tailscale/default\ttrue\tfalse\tpool' mktest::stub_function secrets::inventory
  STUB_OUTPUT="" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::render::_table
  mktest::stub_function secrets::render::_orphans
  secrets::render
  mktest::assert_stub_called secrets::render::_table $'tailscale/default\ttrue\tfalse\tpool'
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

@test "_table prints a blank line, a header, and the resolved source/yes-no columns" {
  STUB_RETURN=1 mktest::stub_function secrets::render::_color_enabled   # color off: assert layout, not ANSI
  run secrets::render::_table $'tailscale/a\ttrue\tfalse\tpool\ngit_backup/bb\ttrue\ttrue\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == $'\n'* ]]   # blank line above the table
  [[ "$output" == *"SECRET"*"SOURCE"*"REQUIRED"*"GENERATE IF MISSING"* ]]
  # pool-backed + required + not-generatable -> pool / yes / no
  [[ "${lines[1]}" == "tailscale/a"*"pool"*" yes "*" no"* ]]
  # missing + required + generatable -> missing / yes / yes
  [[ "${lines[2]}" == "git_backup/bb"*"missing"*" yes "*" yes"* ]]
}

@test "_table shows manager-backed secrets with a manager source" {
  STUB_RETURN=1 mktest::stub_function secrets::render::_color_enabled
  run secrets::render::_table $'hindsight/tenant_api_key\ttrue\ttrue\tmanager'
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "hindsight/tenant_api_key"*"manager"* ]]
}

@test "_table colors each row by its disposition when color is enabled" {
  mktest::stub_function secrets::render::_color_enabled  # default STUB_RETURN 0 = enabled
  run secrets::render::_table $'tailscale/p\ttrue\tfalse\tpool\nhindsight/g\ttrue\ttrue\tmissing\ngit_backup/b\ttrue\tfalse\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32mtailscale/p'* ]]   # resolved (pool) -> green
  [[ "$output" == *$'\033[33mhindsight/g'* ]]   # absent, generatable -> yellow
  [[ "$output" == *$'\033[31mgit_backup/b'* ]]  # absent, required, not generatable -> red blocker
}

@test "_table colors a manager-backed secret green like a pool-backed one" {
  mktest::stub_function secrets::render::_color_enabled
  run secrets::render::_table $'hindsight/tenant_api_key\ttrue\ttrue\tmanager'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32mhindsight/tenant_api_key'* ]]
}

@test "_table emits no color when color is disabled" {
  STUB_RETURN=1 mktest::stub_function secrets::render::_color_enabled
  run secrets::render::_table $'tailscale/a\ttrue\tfalse\tpool'
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
