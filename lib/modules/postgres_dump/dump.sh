#!/usr/bin/env bash
# Standalone, scheduled dump of one or more postgres databases to files.
# postgres_dump installs this and schedules it on a service unit; it runs
# out-of-band, so it depends on nothing but pg_dump/pg_restore and is
# self-contained (it sources no machinekit library).
#
# Each database is dumped in postgres's compressed custom format (-Fc -Z6) to a
# timestamped file, written first to a hidden .partial sibling and renamed only
# once it is complete AND verified — so a half-written or corrupt dump never
# appears as a finished generation. Verification reads the archive's table of
# contents back with `pg_restore --list`; a dump that won't read is deleted and
# notified, and retention does NOT run, because dropping a good older generation
# on the strength of a bad new one is exactly how a backup chain gets emptied.
#
# Retention keeps the newest N generations per database. The UTC timestamp in
# each filename sorts lexically in chronological order, so "newest N" needs no
# stat calls and no mtime comparisons.
#
# This produces files. Whether that amounts to a backup is a property of what
# else is pointed at the directory (a sync mesh, an offsite copy), never of this
# script.
#
# Databases come from a tab-separated manifest, one row per database:
#   <name>\t<directory>\t<retain_count>   (retain_count 0 = keep every generation)
# A database's failure is notified and the run moves on to the next; the script
# exits non-zero if any database failed.
#
# Config via env:
#   MK_POSTGRES_DUMP_MANIFEST    the manifest file (rows as above); required
#   MK_POSTGRES_DUMP_NOTIFY      command run with one message arg on trouble;
#                                optional (default: logger -t machinekit-postgres-dump)
#   MK_POSTGRES_DUMP_PG_DUMP     the pg_dump binary; optional (default: PATH)
#   MK_POSTGRES_DUMP_PG_RESTORE  the pg_restore binary; optional (default: PATH)
#                                The service unit pins both to the resolved
#                                instance's client tools, since the daemon's
#                                minimal PATH won't find them.
#   MK_POSTGRES_DUMP_USER        role to connect as; optional (default: postgres)
#   MK_POSTGRES_DUMP_PORT        port to connect to; optional (default: 5432)
set -euo pipefail

# A generation's filename is <name>-<timestamp>.dump. The pattern is the format's
# exact shape, so retention can tell this database's generations from those of a
# database whose name merely starts with this one (app vs app-staging).
_DUMP_TIMESTAMP_FORMAT='%Y%m%dT%H%M%SZ'
_DUMP_TIMESTAMP_PATTERN='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z'

dump::notify() {
  local message="$1"
  if [ -n "${MK_POSTGRES_DUMP_NOTIFY:-}" ]; then
    "$MK_POSTGRES_DUMP_NOTIFY" "$message" || true
  else
    logger -t machinekit-postgres-dump "$message" 2>/dev/null || printf '%s\n' "$message" >&2
  fi
}

# Notify and exit. Called only inside a per-database subshell (see dump::main), so
# it ends that one database's dump without aborting the rest of the run — and the
# subshell's EXIT trap removes whatever partial file was in flight.
dump::fail() {
  dump::notify "$1"
  exit 1
}

# Dump one database, verify it, publish it, then prune. Runs entirely within a
# subshell (see dump::main) so the EXIT trap and any dump::fail stay scoped to
# this one database.
dump::dump_database() {
  local name="$1" directory="$2" retain_count="$3" timestamp partial final
  mkdir -p "$directory" || dump::fail "postgres_dump: cannot create dump directory $directory."
  timestamp=$(date -u "+$_DUMP_TIMESTAMP_FORMAT")
  final="$directory/$name-$timestamp.dump"
  partial="$directory/.$name-$timestamp.dump.partial"
  # Every exit path from here to the rename removes the in-flight file: a failed
  # dump, a dump that won't verify, a signal. A leading dot keeps it out of the
  # *.dump glob meanwhile, so it can never be mistaken for a generation.
  trap 'rm -f "$partial"' EXIT
  dump::pg_dump "$name" "$partial" \
    || dump::fail "postgres_dump: dump failed for database '$name'."
  dump::verify "$partial" \
    || dump::fail "postgres_dump: dump of '$name' is unreadable (pg_restore --list failed); discarded, and older generations were kept."
  mv "$partial" "$final"
  trap - EXIT
  dump::prune "$name" "$directory" "$retain_count"
}

dump::pg_dump() {
  local name="$1" dest="$2"
  "${MK_POSTGRES_DUMP_PG_DUMP:-pg_dump}" \
    -U "${MK_POSTGRES_DUMP_USER:-postgres}" \
    -p "${MK_POSTGRES_DUMP_PORT:-5432}" \
    -Fc -Z6 -f "$dest" "$name"
}

# Read the archive's table of contents back. Cheap (no data pages are decoded) and
# local, so it catches a truncated or corrupt archive before it is published —
# which plain SQL output has no equivalent for.
dump::verify() {
  "${MK_POSTGRES_DUMP_PG_RESTORE:-pg_restore}" --list "$1" >/dev/null
}

# Keep the newest RETAIN_COUNT generations of NAME and delete the rest. A count of
# 0 means keep everything — the knob for "something else downstream owns
# retention". A non-numeric count is treated the same way rather than risking a
# delete on a value we can't read.
dump::prune() {
  local name="$1" directory="$2" retain_count="$3" stale
  [ "$retain_count" -gt 0 ] 2>/dev/null || return 0
  while IFS= read -u 3 -r stale; do
    [ -n "$stale" ] || continue
    rm -f "$stale"
  done 3< <(dump::stale_generations "$name" "$directory" "$retain_count")
}

# The generations of NAME beyond the newest RETAIN_COUNT, one path per line. The
# filename timestamp is UTC and fixed-width, so a reverse lexical sort is newest
# first.
dump::stale_generations() {
  local name="$1" directory="$2" retain_count="$3"
  dump::generations "$name" "$directory" | sort -r | tail -n "+$((retain_count + 1))"
}

# Every generation of NAME in DIRECTORY, one path per line. The name is quoted in
# the match so a glob character in it is read literally.
dump::generations() {
  local name="$1" directory="$2" path
  for path in "$directory"/*.dump; do
    [[ -f "$path" && "${path##*/}" == "$name-"$_DUMP_TIMESTAMP_PATTERN.dump ]] || continue
    printf '%s\n' "$path"
  done
}

# Iterate the manifest, dumping each database in isolation. A database's failure
# is notified inside its subshell and the loop continues; the run exits non-zero
# if any failed, so the service log records the trouble.
dump::main() {
  local manifest="${MK_POSTGRES_DUMP_MANIFEST:?MK_POSTGRES_DUMP_MANIFEST required}"
  local name directory retain_count failures=0
  while IFS=$'\t' read -u 3 -r name directory retain_count; do
    [ -n "$name" ] || continue
    ( dump::dump_database "$name" "$directory" "$retain_count" ) || failures=$((failures + 1))
  done 3< "$manifest"
  [ "$failures" -eq 0 ] || exit 1
}

# Run only when executed, not when sourced (so tests can exercise functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  dump::main "$@"
fi
