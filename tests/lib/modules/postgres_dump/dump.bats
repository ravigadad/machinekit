#!/usr/bin/env bats
# Tests for lib/modules/postgres_dump/dump.sh — the standalone, manifest-driven
# dump runner. pg_dump and pg_restore are the two external tools it drives, and
# the service unit pins both by absolute path; the tests pin fakes through the
# same env vars, so what is exercised is exactly the production seam.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  SCRIPT="$MACHINEKIT_DIR/lib/modules/postgres_dump/dump.sh"
  DIRECTORY="$BATS_TEST_TMPDIR/dumps"
  MANIFEST="$BATS_TEST_TMPDIR/manifest.tsv"
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
  NOTIFY="$BATS_TEST_TMPDIR/notify.sh"
  PG_DUMP="$BATS_TEST_TMPDIR/pg_dump"
  PG_DUMP_ARGV="$BATS_TEST_TMPDIR/pg_dump.argv"
  PG_RESTORE="$BATS_TEST_TMPDIR/pg_restore"
  PG_RESTORE_ARGV="$BATS_TEST_TMPDIR/pg_restore.argv"
  cat > "$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
EOF
  chmod +x "$NOTIFY"
  fake_pg_dump 0
  fake_pg_restore 0
}

# A pg_dump that records its argv, writes bytes to its -f target, and exits with
# EXIT_STATUS. Writing the file even on the failure path is deliberate: it is what
# a real pg_dump does when it dies partway, and it is what makes the partial-file
# cleanup assertions meaningful.
fake_pg_dump() {
  local exit_status="$1"
  cat > "$PG_DUMP" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PG_DUMP_ARGV"
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-f" ]; then printf 'dump-bytes\n' > "\$2"; fi
  shift
done
exit $exit_status
EOF
  chmod +x "$PG_DUMP"
}

fake_pg_restore() {
  local exit_status="$1"
  cat > "$PG_RESTORE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PG_RESTORE_ARGV"
exit $exit_status
EOF
  chmod +x "$PG_RESTORE"
}

run_manifest() {
  run env \
    MK_POSTGRES_DUMP_MANIFEST="$MANIFEST" \
    MK_POSTGRES_DUMP_NOTIFY="$NOTIFY" \
    MK_POSTGRES_DUMP_PG_DUMP="$PG_DUMP" \
    MK_POSTGRES_DUMP_PG_RESTORE="$PG_RESTORE" \
    MK_POSTGRES_DUMP_USER="fake-superuser" \
    MK_POSTGRES_DUMP_PORT="7777" \
    bash "$SCRIPT"
}

# The common case: one database, dumped into DIRECTORY, keeping RETAIN_COUNT.
run_dump() {
  local retain_count="${1:-3}"
  printf '%s\t%s\t%s\n' "somedb" "$DIRECTORY" "$retain_count" > "$MANIFEST"
  run_manifest
}

# A completed generation already on disk. The name carries the timestamp, so an
# obviously-older one sorts before anything this run writes.
seed_generation() {
  local name="$1" timestamp="$2"
  mkdir -p "$DIRECTORY"
  printf 'old-bytes\n' > "$DIRECTORY/$name-$timestamp.dump"
}

generations() {
  find "$DIRECTORY" -maxdepth 1 -type f \
    -name "$1-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump" | sort
}

generation_count() {
  generations "$1" | grep -c . || true
}

# --- the golden path ---

@test "dumps each database to a timestamped file in its directory" {
  run_dump
  [ "$status" -eq 0 ]
  [ "$(generation_count somedb)" -eq 1 ]
  [ "$(cat "$(generations somedb)")" = "dump-bytes" ]
  [ ! -f "$NOTIFY_LOG" ]
}

@test "creates the destination directory when it does not exist yet" {
  [ ! -d "$DIRECTORY" ]
  run_dump
  [ "$status" -eq 0 ]
  [ -d "$DIRECTORY" ]
}

@test "drives pg_dump in compressed custom format, as the pinned user and port" {
  run_dump
  [ "$status" -eq 0 ]
  # -Fc is the format the verify step and the documented restore both depend on;
  # -Z6 is what keeps the artifact small enough to sync and upload.
  grep -q -- '-Fc' "$PG_DUMP_ARGV"
  grep -q -- '-Z6' "$PG_DUMP_ARGV"
  grep -q -- '-U fake-superuser' "$PG_DUMP_ARGV"
  grep -q -- '-p 7777' "$PG_DUMP_ARGV"
  grep -q -- 'somedb' "$PG_DUMP_ARGV"
}

@test "verifies the finished dump by reading its table of contents back" {
  run_dump
  [ "$status" -eq 0 ]
  grep -q -- '--list' "$PG_RESTORE_ARGV"
}

@test "leaves no partial file behind on a successful run" {
  run_dump
  [ "$status" -eq 0 ]
  [ -z "$(find "$DIRECTORY" -maxdepth 1 -name '.*partial')" ]
}

# --- dump failure ---

@test "a failed dump notifies, leaves nothing behind, and exits non-zero" {
  fake_pg_dump 1
  run_dump
  [ "$status" -ne 0 ]
  grep -q "dump failed" "$NOTIFY_LOG"
  [ "$(generation_count somedb)" -eq 0 ]
  [ -z "$(find "$DIRECTORY" -maxdepth 1 -name '.*partial')" ]
}

@test "a failed dump never reaches the verify step" {
  fake_pg_dump 1
  run_dump
  [ ! -f "$PG_RESTORE_ARGV" ]
}

# --- verify failure blocks pruning (the regression this design exists for) ---

@test "an unreadable dump is deleted and notified rather than kept" {
  fake_pg_restore 1
  run_dump
  [ "$status" -ne 0 ]
  grep -q "unreadable" "$NOTIFY_LOG"
  [ "$(generation_count somedb)" -eq 0 ]
}

@test "an unreadable dump does not prune the good generations it would have replaced" {
  # retain_count 1 would normally leave exactly the newest file. The new dump
  # fails verification, so retention must not run at all — dropping the only good
  # generation on the strength of a bad new one is the failure mode this guards.
  seed_generation somedb 20200101T000000Z
  fake_pg_restore 1
  run_dump 1
  [ "$status" -ne 0 ]
  [ -f "$DIRECTORY/somedb-20200101T000000Z.dump" ]
}

# --- retention ---

@test "keeps the newest retain_count generations and deletes the rest" {
  seed_generation somedb 20200101T000000Z
  seed_generation somedb 20200102T000000Z
  seed_generation somedb 20200103T000000Z
  run_dump 2
  [ "$status" -eq 0 ]
  # The run's own fresh dump plus the newest seeded one.
  [ "$(generation_count somedb)" -eq 2 ]
  [ -f "$DIRECTORY/somedb-20200103T000000Z.dump" ]
  [ ! -f "$DIRECTORY/somedb-20200101T000000Z.dump" ]
  [ ! -f "$DIRECTORY/somedb-20200102T000000Z.dump" ]
}

@test "a retain_count of 0 keeps every generation" {
  seed_generation somedb 20200101T000000Z
  run_dump 0
  [ "$status" -eq 0 ]
  [ "$(generation_count somedb)" -eq 2 ]
}

@test "retention never touches another database's generations in the same directory" {
  seed_generation otherdb 20200101T000000Z
  seed_generation otherdb 20200102T000000Z
  run_dump 1
  [ "$status" -eq 0 ]
  [ "$(generation_count otherdb)" -eq 2 ]
}

@test "retention never touches a database whose name starts with this one's" {
  seed_generation somedb-staging 20200101T000000Z
  seed_generation somedb-staging 20200102T000000Z
  run_dump 1
  [ "$status" -eq 0 ]
  [ "$(generation_count somedb-staging)" -eq 2 ]
  [ "$(generation_count somedb)" -eq 1 ]
}

@test "retention reads a glob character in a database name literally" {
  seed_generation someXdb 20200101T000000Z
  printf '%s\t%s\t%s\n' "some?db" "$DIRECTORY" 1 > "$MANIFEST"
  run_manifest
  [ "$status" -eq 0 ]
  [ "$(generation_count someXdb)" -eq 1 ]
  [ "$(find "$DIRECTORY" -maxdepth 1 -type f -name '*.dump' | grep -c .)" -eq 2 ]
}

# --- multiple databases ---

@test "dumps every database in the manifest" {
  printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
    "somedb" "$DIRECTORY" 3 \
    "otherdb" "$BATS_TEST_TMPDIR/other-dumps" 3 > "$MANIFEST"
  run_manifest
  [ "$status" -eq 0 ]
  [ "$(generation_count somedb)" -eq 1 ]
  [ -n "$(find "$BATS_TEST_TMPDIR/other-dumps" -maxdepth 1 -name 'otherdb-*.dump')" ]
}

@test "isolates a failing database: the others still dump and the run exits non-zero" {
  # pg_dump fails only for the first database, so the second must still complete.
  cat > "$PG_DUMP" <<EOF
#!/usr/bin/env bash
args="\$*"
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-f" ]; then printf 'dump-bytes\n' > "\$2"; fi
  shift
done
case "\$args" in *faildb*) exit 1 ;; esac
EOF
  chmod +x "$PG_DUMP"
  printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
    "faildb" "$DIRECTORY" 3 \
    "somedb" "$DIRECTORY" 3 > "$MANIFEST"
  run_manifest
  [ "$status" -ne 0 ]
  grep -q "dump failed" "$NOTIFY_LOG"
  [ "$(generation_count somedb)" -eq 1 ]
  [ "$(generation_count faildb)" -eq 0 ]
}
