#!/usr/bin/env bash
# Standalone scan for Syncthing's *.sync-conflict-* files. syncthing installs
# this and schedules it on a service unit; it runs out-of-band, so it depends
# on nothing but find and is self-contained (it sources no machinekit library).
#
# Syncthing silently renames the losing side of a concurrent same-file edit to
# *.sync-conflict-*; nothing else surfaces it. This scans every configured
# folder recursively and, if any conflict files exist, notifies once with all
# of their paths. There is no seen/last-notified state — it re-notifies on
# every run while conflict files remain, a nag until they're resolved rather
# than a one-time ping that could be missed.
#
# Folders come from a manifest, one path per line. A path that doesn't
# currently exist is treated as having no conflicts, not an error.
#
# Config via env:
#   MK_SYNCTHING_CONFLICT_MANIFEST  the manifest file (paths as above); required
#   MK_SYNCTHING_CONFLICT_NOTIFY    command run with one message arg on trouble;
#                                    optional (default: logger -t machinekit-syncthing-conflicts)
set -euo pipefail

conflict_scan::notify() {
  local message="$1"
  if [ -n "${MK_SYNCTHING_CONFLICT_NOTIFY:-}" ]; then
    "$MK_SYNCTHING_CONFLICT_NOTIFY" "$message" || true
  else
    logger -t machinekit-syncthing-conflicts "$message" 2>/dev/null || printf '%s\n' "$message" >&2
  fi
}

# Conflict file paths under one folder, one per line (empty if none, including
# when the folder doesn't currently exist).
conflict_scan::find_in_folder() {
  local folder="$1"
  [ -d "$folder" ] || return 0
  find "$folder" -name '*.sync-conflict-*'
}

conflict_scan::main() {
  local manifest="${MK_SYNCTHING_CONFLICT_MANIFEST:?MK_SYNCTHING_CONFLICT_MANIFEST required}"
  local folder conflicts=""
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    conflicts+="$(conflict_scan::find_in_folder "$folder")"$'\n'
  done < "$manifest"
  conflicts=$(printf '%s' "$conflicts" | awk 'NF')
  [ -n "$conflicts" ] || return 0
  conflict_scan::notify "syncthing: unresolved sync-conflict files:
$conflicts"
}

# Run only when executed, not when sourced (so tests can exercise functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  conflict_scan::main "$@"
fi
