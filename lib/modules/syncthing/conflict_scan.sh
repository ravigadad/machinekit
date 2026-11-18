#!/usr/bin/env bash
# Scheduled scan for Syncthing's *.sync-conflict-* files. syncthing installs this
# and schedules it on a service unit; it runs out-of-band, so it depends on
# nothing but find and the job library installed beside it
# (lib/machinekit/service/job.sh), which reports what it finds and any trouble.
#
# Syncthing silently renames the losing side of a concurrent same-file edit to
# *.sync-conflict-*; nothing else surfaces it. This scans every configured
# folder recursively and, if any conflict files exist, notifies once with all
# of their paths. There is no seen/last-notified state — it re-notifies on
# every run while conflict files remain, a nag until they're resolved rather
# than a one-time ping that could be missed.
#
# Folders come from a manifest, one path per line. A path that doesn't
# currently exist is treated as having no conflicts, not an error. A scan that
# fails alerts through the job library's exit handler.
#
# Config via env:
#   MK_SYNCTHING_CONFLICT_MANIFEST  the manifest file (paths as above); required
#   MK_SYNCTHING_CONFLICT_NOTIFY    command run with one message arg on trouble;
#                                    optional (default: logger -t machinekit-syncthing-conflicts)
#   MK_JOB_LIBRARY                  the job library; optional (default: job.sh beside
#                                    this script, where it is installed)
set -euo pipefail

# shellcheck source=../../machinekit/service/job.sh
source "${MK_JOB_LIBRARY:-$(dirname "${BASH_SOURCE[0]}")/job.sh}"

# Conflict file paths under one folder, one per line (empty if none, including
# when the folder doesn't currently exist).
conflict_scan::find_in_folder() {
  local folder="$1"
  [ -d "$folder" ] || return 0
  find "$folder" -name '*.sync-conflict-*'
}

conflict_scan::main() {
  job::configure machinekit-syncthing-conflicts "${MK_SYNCTHING_CONFLICT_NOTIFY:-}"
  job::alert_on_unexpected_exit "syncthing: the conflict scan"
  local manifest="${MK_SYNCTHING_CONFLICT_MANIFEST:?MK_SYNCTHING_CONFLICT_MANIFEST required}"
  local folder conflicts=""
  while IFS= read -u 3 -r folder; do
    [ -n "$folder" ] || continue
    conflicts+="$(conflict_scan::find_in_folder "$folder")"$'\n'
  done 3< "$manifest"
  conflicts=$(printf '%s' "$conflicts" | awk 'NF')
  [ -n "$conflicts" ] || return 0
  job::notify "syncthing: unresolved sync-conflict files:
$conflicts"
}

# Run only when executed, not when sourced (so tests can exercise functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  conflict_scan::main "$@"
fi
