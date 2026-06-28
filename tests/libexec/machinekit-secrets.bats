#!/usr/bin/env bats
# Tests for libexec/machinekit-secrets

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  set --  # prevent the top-level flag parser from consuming bats's internal $@
  # shellcheck source=../../libexec/machinekit-secrets
  source "$MACHINEKIT_DIR/libexec/machinekit-secrets"

  # The read-only resolve pipeline — heavy collaborators that must never really
  # run. Stubbed here so the cascade can be asserted without side effects.
  mktest::stub_function context::init_storage
  mktest::stub_function brew::bootstrap
  mktest::stub_function prerequisites::install
  mktest::stub_function context::seed_from_flags
  mktest::stub_function context::load_user_config
  mktest::stub_function input::detect_mode
  mktest::stub_function preflight::resolve_inputs
  mktest::stub_function logging::info
}

# --- BASH_SOURCE guard ---

@test "sourcing does not auto-execute main" {
  # The guard kept main() from running during source in setup; had it run, the
  # real pipeline (not yet stubbed at source time) would have failed setup.
  mktest::assert_stub_not_called context::init_storage
}

# --- main / secrets::cli::list ---

@test "main runs the read-only resolve pipeline, then renders, in order" {
  mktest::stub_function secrets::cli::render
  main
  mktest::assert_stub_called_in_order context::init_storage
  mktest::assert_stub_called_in_order brew::bootstrap
  mktest::assert_stub_called_in_order prerequisites::install
  mktest::assert_stub_called_in_order context::seed_from_flags
  mktest::assert_stub_called_in_order context::load_user_config
  mktest::assert_stub_called_in_order input::detect_mode
  mktest::assert_stub_called_in_order preflight::resolve_inputs
  mktest::assert_stub_called_in_order secrets::cli::render
}

@test "main fails on an unknown command" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  COMMAND=bogus
  run main
  [ "$status" -ne 0 ]
  MATCH="Unknown command" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::cli::render ---

@test "render reports nothing to show when no secrets are needed or present" {
  STUB_OUTPUT="" mktest::stub_function secrets::inventory
  STUB_OUTPUT="" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::cli::_render_table
  mktest::stub_function secrets::cli::_render_orphans
  secrets::cli::render
  mktest::assert_stub_not_called secrets::cli::_render_table
  MATCH="No pool secrets" mktest::assert_stub_called logging::info
}

@test "render delegates to the table when secrets are declared" {
  STUB_OUTPUT=$'secrets/x.age\ttrue\tfalse\tprovided' mktest::stub_function secrets::inventory
  STUB_OUTPUT="" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::cli::_render_table
  mktest::stub_function secrets::cli::_render_orphans
  secrets::cli::render
  mktest::assert_stub_called secrets::cli::_render_table $'secrets/x.age\ttrue\tfalse\tprovided'
  mktest::assert_stub_not_called secrets::cli::_render_orphans
}

@test "render lists orphans separately when the pool has unrecognized secrets" {
  STUB_OUTPUT="" mktest::stub_function secrets::inventory
  STUB_OUTPUT="secrets/stray.age" mktest::stub_function secrets::orphans
  mktest::stub_function secrets::cli::_render_table
  mktest::stub_function secrets::cli::_render_orphans
  secrets::cli::render
  mktest::assert_stub_called secrets::cli::_render_orphans "secrets/stray.age"
  mktest::assert_stub_not_called secrets::cli::_render_table
}

# --- secrets::cli::_render_table ---

@test "_render_table prints a blank line, a header, and yes/no columns from the booleans" {
  run secrets::cli::_render_table $'secrets/a.age\ttrue\tfalse\tprovided\nsecrets/bb.age\ttrue\ttrue\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == $'\n'* ]]   # blank line above the table
  [[ "$output" == *"SECRET"*"IN POOL"*"REQUIRED"*"GENERATE IF MISSING"* ]]
  # provided + required + not-generatable -> yes / yes / no
  [[ "${lines[1]}" == "secrets/a.age"*" yes "*" yes "*" no"* ]]
  # missing + required + generatable -> no / yes / yes
  [[ "${lines[2]}" == "secrets/bb.age"*" no "*" yes "*" yes"* ]]
}

@test "_render_table colors each row by its disposition when color is enabled" {
  mktest::stub_function secrets::cli::_color_enabled  # default STUB_RETURN 0 = enabled
  run secrets::cli::_render_table $'secrets/p.age\ttrue\tfalse\tprovided\nsecrets/g.age\ttrue\ttrue\tmissing\nsecrets/b.age\ttrue\tfalse\tmissing'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32msecrets/p.age'* ]]   # in pool -> green
  [[ "$output" == *$'\033[33msecrets/g.age'* ]]   # absent, generatable -> yellow
  [[ "$output" == *$'\033[31msecrets/b.age'* ]]   # absent, required, not generatable -> red blocker
}

@test "_render_table emits no color when color is disabled" {
  STUB_RETURN=1 mktest::stub_function secrets::cli::_color_enabled
  run secrets::cli::_render_table $'secrets/a.age\ttrue\tfalse\tprovided'
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

# --- secrets::cli::_render_orphans ---

@test "_render_orphans lists each stray under a heading" {
  run secrets::cli::_render_orphans $'secrets/stray1.age\nsecrets/stray2.age'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unrecognized secrets in the pool"* ]]
  [[ "$output" == *"  secrets/stray1.age"* ]]
  [[ "$output" == *"  secrets/stray2.age"* ]]
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

@test "unknown command exits 1" {
  run "$MACHINEKIT_DIR/libexec/machinekit-secrets" bogus
  [ "$status" -eq 1 ]
}

@test "run directly under a bash below the floor fails cleanly" {
  run /bin/bash "$MACHINEKIT_DIR/libexec/machinekit-secrets" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"bash >= 5.3 required"* ]]
}
