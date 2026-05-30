#!/usr/bin/env bats
# Tests for lib/modules/zsh.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/zsh.sh
  source "$MACHINEKIT_DIR/lib/modules/zsh.sh"
}

# --- zsh::install ---

@test "install is a no-op" {
  zsh::install
}
