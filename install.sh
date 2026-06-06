#!/bin/bash
# Bootstrap machinekit on a fresh machine.
#
# Usage (brew-style one-liner):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravigadad/machinekit/main/install.sh)" -- [flags]
#
# All flags are passed through to machinekit apply — run with --help to see them.
# Override the framework location: MACHINEKIT_FRAMEWORK_DIR=/your/path

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

exec "$MACHINEKIT_DIR/bin/machinekit-apply" "$@"
