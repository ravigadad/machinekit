#!/usr/bin/env bats
# Tests for lib/machinekit/secrets/cli.sh — the controller actions.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/secrets/cli.sh
  source "$MACHINEKIT_DIR/lib/machinekit/secrets/cli.sh"

  # The framework-setup collaborators both actions share — stubbed so the
  # orchestration can be asserted without side effects.
  mktest::stub_function context::init_storage
  mktest::stub_function brew::bootstrap
  mktest::stub_function prerequisites::install
  mktest::stub_function context::seed_from_flags
  mktest::stub_function context::load_user_config
  mktest::stub_function input::detect_mode
  mktest::stub_function preflight::resolve_inputs
}

# --- secrets::cli::dispatch ---

@test "dispatch routes list to the list action" {
  mktest::stub_function secrets::cli::list
  mktest::stub_function secrets::cli::put
  secrets::cli::dispatch list "" ""
  mktest::assert_stub_called secrets::cli::list
  mktest::assert_stub_not_called secrets::cli::put
}

@test "dispatch routes put to the put action with the target and from-file" {
  mktest::stub_function secrets::cli::list
  mktest::stub_function secrets::cli::put "secrets/x.age" "/tmp/val"
  secrets::cli::dispatch put "secrets/x.age" "/tmp/val"
  mktest::assert_stub_called secrets::cli::put "secrets/x.age" "/tmp/val"
  mktest::assert_stub_not_called secrets::cli::list
}

@test "dispatch fails on an unknown command" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::cli::dispatch bogus "" ""
  MATCH="unknown command" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::cli::list ---

@test "list bootstraps, resolves inputs, readies the secrets manager, asserts the age-key invariant, then renders, in order" {
  mktest::stub_function secrets::cli::_bootstrap
  mktest::stub_function secrets_manager::ensure_ready
  mktest::stub_function secrets::assert_age_key_not_pooled
  mktest::stub_function age::assert_key_source_type
  mktest::stub_function secrets::render
  secrets::cli::list
  mktest::assert_stub_called_in_order secrets::cli::_bootstrap
  mktest::assert_stub_called_in_order preflight::resolve_inputs
  mktest::assert_stub_called_in_order secrets_manager::ensure_ready
  mktest::assert_stub_called_in_order secrets::assert_age_key_not_pooled
  mktest::assert_stub_called_in_order age::assert_key_source_type
  mktest::assert_stub_called_in_order secrets::render
}

# --- secrets::cli::put ---

@test "put bootstraps, then runs the put use-case with its args" {
  mktest::stub_function secrets::cli::_bootstrap
  mktest::stub_function secrets::put "secrets/x.age" "/tmp/val"
  secrets::cli::put "secrets/x.age" "/tmp/val"
  mktest::assert_stub_called_in_order secrets::cli::_bootstrap
  mktest::assert_stub_called_in_order secrets::put "secrets/x.age" "/tmp/val"
}

# --- secrets::cli::_bootstrap ---

@test "_bootstrap runs the shared framework setup in order" {
  secrets::cli::_bootstrap
  mktest::assert_stub_called_in_order context::init_storage
  mktest::assert_stub_called_in_order brew::bootstrap
  mktest::assert_stub_called_in_order prerequisites::install
  mktest::assert_stub_called_in_order context::seed_from_flags
  mktest::assert_stub_called_in_order context::load_user_config
  mktest::assert_stub_called_in_order input::detect_mode
}
