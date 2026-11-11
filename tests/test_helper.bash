#!/usr/bin/env bash
# Shared setup for all bats test files.
# Load with: load 'test_helper'

bats_require_minimum_version 1.5.0

MACHINEKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MACHINEKIT_DIR

# Silence machinekit output during tests unless MACHINEKIT_VERBOSE=1.
export MACHINEKIT_VERBOSE="${MACHINEKIT_VERBOSE:-0}"

source "$(dirname "${BASH_SOURCE[0]}")/helpers/stubbing.sh"

# File mode in octal. GNU stat (Linux/CI) uses -c '%a'; BSD stat (macOS) uses
# -f '%A'. Try GNU first, fall back to BSD, so assertions are OS-portable.
mktest::file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1"; }

# The floor tests use the system /bin/bash as their old bash. That holds on macOS,
# where /bin/bash is 3.2, but a Linux distro's /bin/bash can meet the floor, and
# then there is no old bash to test against.
mktest::skip_unless_system_bash_below_floor() {
  /bin/bash -c "source '$MACHINEKIT_DIR/lib/common/bash_floor.sh'; ! bash_floor::meets \"\${BASH_VERSINFO[0]}\" \"\${BASH_VERSINFO[1]}\"" \
    || skip "/bin/bash meets the bash floor, so there is no old bash to test against"
}
