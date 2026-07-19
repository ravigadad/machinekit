#!/usr/bin/env bats
# Tests for lib/modules/git_aliases.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/git_aliases.sh
  source "$MACHINEKIT_DIR/lib/modules/git_aliases.sh"
}

# --- git_aliases::requires ---

@test "requires declares zsh as a dependency" {
  result=$(git_aliases::requires)
  printf '%s\n' "$result" | grep -q '^zsh$'
}

# --- git_aliases::postflight_info ---

@test "postflight_info reports where the alias library was installed" {
  run git_aliases::postflight_info
  [[ "$output" == *".git_aliases.zsh"* ]]
}

# --- git_aliases::postflight_instructions ---

@test "postflight_instructions points to how the aliases are discovered" {
  run git_aliases::postflight_instructions
  [[ "$output" == *"alias"* ]]
  [[ "$output" == *"github.com/ohmyzsh"* ]]
}
