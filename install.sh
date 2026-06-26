#!/bin/bash
# Install machinekit on a fresh machine: fetch the framework and ensure its
# prerequisites, leaving the tool ready to run. It does NOT apply a blueprint —
# installing machinekit and applying a blueprint are separate steps, and a
# first-time installer usually has no blueprint yet.
#
# Usage (brew-style one-liner):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravigadad/machinekit/main/install.sh)"
#
# Override the framework location: MACHINEKIT_FRAMEWORK_DIR=/your/path
#
# Runs under stock /bin/bash, so keep this file 3.2-safe (part of the bootstrap
# island — see lib/common/bash_floor.sh).

set -euo pipefail

MACHINEKIT_REPO="https://github.com/ravigadad/machinekit.git"
MACHINEKIT_DIR="${MACHINEKIT_FRAMEWORK_DIR:-$HOME/.local/share/machinekit/framework}"

if [ -d "$MACHINEKIT_DIR/.git" ]; then
  printf 'machinekit: updating %s\n' "$MACHINEKIT_DIR" >&2
  git -C "$MACHINEKIT_DIR" pull --ff-only
else
  printf 'machinekit: cloning to %s\n' "$MACHINEKIT_DIR" >&2
  mkdir -p "$(dirname "$MACHINEKIT_DIR")"
  git clone "$MACHINEKIT_REPO" "$MACHINEKIT_DIR"
fi

# Ensure a bash that meets the version floor exists, installing Homebrew's bash if
# the system one is too old. machinekit resolves this on every run too, but doing it
# at install time means the first run isn't surprised by a mid-apply install.
# shellcheck source=lib/bootstrap/bash.sh
source "$MACHINEKIT_DIR/lib/bootstrap/bash.sh"
bootstrap::bash::ensure_modern_bash >/dev/null

printf 'machinekit: installed to %s\n' "$MACHINEKIT_DIR" >&2
printf 'machinekit: run %s/bin/machinekit apply --help to get started, or add %s/bin to your PATH.\n' \
  "$MACHINEKIT_DIR" "$MACHINEKIT_DIR" >&2
