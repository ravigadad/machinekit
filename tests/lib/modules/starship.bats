#!/usr/bin/env bats
# Tests for lib/modules/starship.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/starship.sh
  source "$MACHINEKIT_DIR/lib/modules/starship.sh"

  # Logging collaborators — allow-only; logging is mechanism, not contract.
  mktest::stub_function logging::step
}

# --- starship::requires ---

@test "requires declares zsh as a dependency" {
  result=$(starship::requires)
  printf '%s\n' "$result" | grep -q '^zsh$'
}

# --- starship::install ---

@test "install ensures starship is present via brew" {
  mktest::stub_function brew::install_formula "starship"
  starship::install
  mktest::assert_stub_called brew::install_formula "starship"
}

# --- starship::postflight_info ---

@test "postflight_info reports the prompt and its config path" {
  run starship::postflight_info
  [[ "$output" == *"starship"* ]]
  [[ "$output" == *"config.toml"* ]]
}

# --- starship::postflight_instructions ---

@test "postflight_instructions covers nerd fonts and personalization" {
  run starship::postflight_instructions
  [[ "$output" == *"Nerd Font"* ]]
  [[ "$output" == *"starship.rs"* ]]
}
