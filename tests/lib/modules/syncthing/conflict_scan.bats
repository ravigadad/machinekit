#!/usr/bin/env bats
# Tests for lib/modules/syncthing/conflict_scan.sh — the standalone,
# manifest-driven scan for Syncthing's *.sync-conflict-* files, exercised
# against real local directories.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  SCRIPT="$MACHINEKIT_DIR/lib/modules/syncthing/conflict_scan.sh"
  MANIFEST="$BATS_TEST_TMPDIR/manifest.txt"
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
  # One line per invocation, so a message with embedded newlines (the conflict
  # list) still counts as a single call.
  CALL_COUNT="$BATS_TEST_TMPDIR/notify.calls"
  NOTIFY="$BATS_TEST_TMPDIR/notify.sh"
  cat > "$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
printf 'x\n' >> "$CALL_COUNT"
EOF
  chmod +x "$NOTIFY"
}

run_scan() {
  run env MK_SYNCTHING_CONFLICT_MANIFEST="$MANIFEST" MK_SYNCTHING_CONFLICT_NOTIFY="$NOTIFY" bash "$SCRIPT"
}

@test "is a clean no-op when a configured folder has no conflict files" {
  local folder="$BATS_TEST_TMPDIR/f1"
  mkdir -p "$folder"
  printf 'hello\n' > "$folder/normal.txt"
  printf '%s\n' "$folder" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

@test "notifies with the conflicting file's path when one exists" {
  local folder="$BATS_TEST_TMPDIR/f1"
  mkdir -p "$folder"
  printf 'conflict\n' > "$folder/notes.sync-conflict-20260101-120000.txt"
  printf '%s\n' "$folder" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  grep -q "notes.sync-conflict-20260101-120000.txt" "$NOTIFY_LOG"
}

@test "finds a conflict file nested in a subdirectory" {
  local folder="$BATS_TEST_TMPDIR/f1"
  mkdir -p "$folder/nested/deep"
  printf 'conflict\n' > "$folder/nested/deep/a.sync-conflict-20260101-120000.txt"
  printf '%s\n' "$folder" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  grep -q "nested/deep/a.sync-conflict-20260101-120000.txt" "$NOTIFY_LOG"
}

@test "scans every folder in the manifest and reports conflicts from all of them" {
  local folder1="$BATS_TEST_TMPDIR/f1" folder2="$BATS_TEST_TMPDIR/f2"
  mkdir -p "$folder1" "$folder2"
  printf 'x\n' > "$folder1/a.sync-conflict-20260101-120000.txt"
  printf 'y\n' > "$folder2/b.sync-conflict-20260101-120000.txt"
  printf '%s\n%s\n' "$folder1" "$folder2" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  grep -q "a.sync-conflict-20260101-120000.txt" "$NOTIFY_LOG"
  grep -q "b.sync-conflict-20260101-120000.txt" "$NOTIFY_LOG"
}

@test "notifies exactly once per run even when multiple conflicts exist" {
  local folder="$BATS_TEST_TMPDIR/f1"
  mkdir -p "$folder"
  printf 'x\n' > "$folder/a.sync-conflict-20260101-120000.txt"
  printf 'y\n' > "$folder/b.sync-conflict-20260101-130000.txt"
  printf '%s\n' "$folder" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALL_COUNT")" -eq 1 ]
}

@test "treats a folder path that no longer exists as having no conflicts" {
  printf '%s\n' "$BATS_TEST_TMPDIR/absent" > "$MANIFEST"
  run_scan
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

@test "re-notifies on a subsequent run while the conflict file still exists" {
  local folder="$BATS_TEST_TMPDIR/f1"
  mkdir -p "$folder"
  printf 'conflict\n' > "$folder/notes.sync-conflict-20260101-120000.txt"
  printf '%s\n' "$folder" > "$MANIFEST"
  run_scan
  run_scan
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALL_COUNT")" -eq 2 ]
}
