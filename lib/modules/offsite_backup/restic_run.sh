#!/usr/bin/env bash
# Standalone, scheduled restic driver. offsite_backup installs this once and
# schedules it twice — a frequent backup run and a rarer repository check — so it
# runs out-of-band, depends on nothing but restic, and is self-contained (it
# sources no machinekit library). Which of the two jobs a given service unit runs
# is pinned in its environment, because the scheduler primitive takes an
# executable and no arguments.
#
# Four modes, all sharing one credential setup. Two are scheduled: `backup` backs
# each configured path up, notices a path whose contents have gone stale, then
# forget-and-prunes to the keep policy; `check` verifies the repository. Two are
# for apply time, run by the module rather than by a timer: `probe` answers
# whether the repository exists, and `init` creates it. They live here rather
# than in the module so the credential handling has exactly one home.
#
# Credentials are carried opaquely as KEY=value lines: every restic backend reads
# different variable names (AWS_ACCESS_KEY_ID, B2_ACCOUNT_ID, …), so the file is
# exported verbatim rather than modelled per provider. It is read, never sourced —
# a credentials file must not be able to execute arbitrary shell.
#
# Snapshots are tagged, and forget filters on that tag: a repository may hold
# snapshots this machine did not write, and an untagged `forget --prune` would
# delete them.
#
# Paths come from a tab-separated manifest, one row per path:
#   <path>\t<max_age_hours>   (empty or 0 = no staleness deadline)
# A path's failure is notified and the run moves on to the next; the script exits
# non-zero if anything failed.
#
# Config via env:
#   MK_OFFSITE_BACKUP_MODE              backup | check | probe | init; required
#   MK_OFFSITE_BACKUP_MANIFEST          the manifest file (rows as above); required
#                                       in backup mode
#   MK_OFFSITE_BACKUP_NOTIFY            command run with one message arg on trouble;
#                                       optional (default: logger -t machinekit-offsite-backup)
#   MK_OFFSITE_BACKUP_RESTIC            the restic binary; optional (default: PATH).
#                                       The service unit pins the installed one,
#                                       since the daemon's minimal PATH won't find it.
#   MK_OFFSITE_BACKUP_REPOSITORY        the restic repository string; required
#   MK_OFFSITE_BACKUP_PASSWORD_FILE     file holding the repository password; required
#   MK_OFFSITE_BACKUP_CREDENTIALS_FILE  KEY=value lines for the backend; optional
#   MK_OFFSITE_BACKUP_KEEP_DAILY        \
#   MK_OFFSITE_BACKUP_KEEP_WEEKLY        > retention windows; all optional, but with
#   MK_OFFSITE_BACKUP_KEEP_MONTHLY      /  none of them set, nothing is ever pruned
#   MK_OFFSITE_BACKUP_READ_DATA         check mode: "true" re-downloads and re-reads
#                                       every pack (expensive, and the one operation
#                                       with real egress cost)
set -euo pipefail

# Only snapshots carrying this tag are ours to forget.
_RESTIC_RUN_TAG="machinekit"

restic_run::notify() {
  local message="$1"
  if [ -n "${MK_OFFSITE_BACKUP_NOTIFY:-}" ]; then
    "$MK_OFFSITE_BACKUP_NOTIFY" "$message" || true
  else
    logger -t machinekit-offsite-backup "$message" 2>/dev/null || printf '%s\n' "$message" >&2
  fi
}

# Put the repository, its password file, and the backend's credentials into the
# environment restic reads. The service unit pins the two secret *paths*, never
# their values — a launchd plist is readable at rest — so the values are read
# here, at run time.
restic_run::export_credentials() {
  export RESTIC_REPOSITORY="${MK_OFFSITE_BACKUP_REPOSITORY:?MK_OFFSITE_BACKUP_REPOSITORY required}"
  export RESTIC_PASSWORD_FILE="${MK_OFFSITE_BACKUP_PASSWORD_FILE:?MK_OFFSITE_BACKUP_PASSWORD_FILE required}"
  local credentials_file="${MK_OFFSITE_BACKUP_CREDENTIALS_FILE:-}"
  [ -n "$credentials_file" ] && [ -f "$credentials_file" ] || return 0
  restic_run::export_key_value_file "$credentials_file"
}

# Export each KEY=value line of FILE. Read, not sourced: the file holds secret
# material from a backend the operator chose, and sourcing it would execute
# whatever it contains. Everything after the first `=` is the value, so a
# base64-ish secret carrying its own `=` survives intact. Blank lines, comments,
# and anything that isn't a shell-identifier assignment are skipped rather than
# fatal — this runs before the mode dispatch, so dying here would take the job
# down with nothing notified. The `|| [ -n "$line" ]` catches a final line with
# no trailing newline.
restic_run::export_key_value_file() {
  local file="$1" line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    export "${key}=${value}"
  done < "$file"
}

restic_run::restic() {
  "${MK_OFFSITE_BACKUP_RESTIC:-restic}" "$@"
}

restic_run::backup_path() {
  restic_run::restic backup --tag "$_RESTIC_RUN_TAG" "$1"
}

# Drop snapshots outside the keep policy and reclaim their space. With no window
# configured this does nothing at all: `forget --prune` with no --keep-* would
# delete every snapshot in the repository, which is the opposite of what an
# unconfigured retention policy should mean.
restic_run::forget() {
  local -a keep_options=()
  local option
  while IFS= read -r option; do
    [ -n "$option" ] || continue
    keep_options+=("$option")
  done < <(restic_run::keep_options)
  [ "${#keep_options[@]}" -gt 0 ] || return 0
  restic_run::restic forget --tag "$_RESTIC_RUN_TAG" --prune "${keep_options[@]}"
}

# The --keep-* flags for whichever windows are configured, one token per line.
restic_run::keep_options() {
  [ -n "${MK_OFFSITE_BACKUP_KEEP_DAILY:-}" ]   && printf '%s\n' --keep-daily   "$MK_OFFSITE_BACKUP_KEEP_DAILY"
  [ -n "${MK_OFFSITE_BACKUP_KEEP_WEEKLY:-}" ]  && printf '%s\n' --keep-weekly  "$MK_OFFSITE_BACKUP_KEEP_WEEKLY"
  [ -n "${MK_OFFSITE_BACKUP_KEEP_MONTHLY:-}" ] && printf '%s\n' --keep-monthly "$MK_OFFSITE_BACKUP_KEEP_MONTHLY"
  return 0
}

# Notify (and report failure) when nothing under PATH has changed inside its
# deadline. This is the silent-failure alarm: whatever writes into the path can
# stop while the upload keeps succeeding, and nothing else would ever say so.
# No deadline configured = nothing to check.
restic_run::warn_if_stale() {
  local path="$1" max_age_hours="$2"
  [ -n "$max_age_hours" ] && [ "$max_age_hours" -gt 0 ] 2>/dev/null || return 0
  restic_run::has_recent_file "$path" "$max_age_hours" && return 0
  restic_run::notify "offsite_backup: nothing under $path has changed in ${max_age_hours}h — whatever writes there may have stopped."
  return 1
}

# -mmin (rather than -newermt or a computed reference file) because it is the one
# spelling both BSD and GNU find agree on.
restic_run::has_recent_file() {
  local path="$1" max_age_hours="$2" recent
  recent=$(find "$path" -type f -mmin "-$((max_age_hours * 60))" 2>/dev/null | head -n 1) || true
  [ -n "$recent" ]
}

# Back up every path in the manifest, checking each one's staleness whether or not
# its upload succeeded (the deadline diagnoses the source, not the upload), then
# prune once for the whole run.
restic_run::backup_all() {
  local manifest="${MK_OFFSITE_BACKUP_MANIFEST:?MK_OFFSITE_BACKUP_MANIFEST required}"
  local path max_age_hours failures=0
  while IFS=$'\t' read -r path max_age_hours; do
    [ -n "$path" ] || continue
    restic_run::backup_path "$path" || {
      restic_run::notify "offsite_backup: backup failed for $path."
      failures=$((failures + 1))
    }
    restic_run::warn_if_stale "$path" "$max_age_hours" || failures=$((failures + 1))
  done < "$manifest"
  restic_run::forget || {
    restic_run::notify "offsite_backup: prune failed; snapshots outside the keep policy are still there."
    failures=$((failures + 1))
  }
  [ "$failures" -eq 0 ] || exit 1
}

# Answer whether the repository exists and opens with this password — reading its
# config is the cheapest way to ask. Silent either way, and it never notifies: an
# absent repository is the expected answer on a first apply, not trouble. This is
# the question offsite_backup's install asks before deciding whether to seek
# consent to create one.
restic_run::probe() {
  restic_run::restic cat config >/dev/null 2>&1
}

# Create the repository. Reached only once the operator has consented, and only
# when probe has already said there is nothing there.
restic_run::init() {
  restic_run::restic init || {
    restic_run::notify "offsite_backup: the repository could not be created — check the destination and the backend credentials."
    exit 1
  }
}

# Verify the repository. Structure only by default — --read-data re-downloads
# every pack, so it stays opt-in and is the one operation with real egress cost
# on a paid-egress backend.
restic_run::check() {
  local -a options=()
  [ "${MK_OFFSITE_BACKUP_READ_DATA:-false}" = "true" ] && options+=(--read-data)
  restic_run::restic check "${options[@]}" || {
    restic_run::notify "offsite_backup: repository check failed — the remote copy may not be restorable."
    exit 1
  }
}

restic_run::main() {
  local mode="${MK_OFFSITE_BACKUP_MODE:?MK_OFFSITE_BACKUP_MODE required}"
  restic_run::export_credentials
  case "$mode" in
    backup) restic_run::backup_all ;;
    check)  restic_run::check ;;
    probe)  restic_run::probe ;;
    init)   restic_run::init ;;
    *)
      restic_run::notify "offsite_backup: unknown mode '$mode' (expected backup, check, probe, or init)."
      exit 1
      ;;
  esac
}

# Run only when executed, not when sourced (so tests can exercise functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  restic_run::main "$@"
fi
