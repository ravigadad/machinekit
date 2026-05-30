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
