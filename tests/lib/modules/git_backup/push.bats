#!/usr/bin/env bats
# Tests for lib/modules/git_backup/push.sh — the standalone, manifest-driven
# push-only-with-abort backup script, exercised against real local git repos.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  SCRIPT="$MACHINEKIT_DIR/lib/modules/git_backup/push.sh"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WORK="$BATS_TEST_TMPDIR/work"
  MANIFEST="$BATS_TEST_TMPDIR/manifest.tsv"
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
  NOTIFY="$BATS_TEST_TMPDIR/notify.sh"
  cat > "$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
EOF
  chmod +x "$NOTIFY"
  git init --bare -q "$ORIGIN"
}

tgit() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# Run the script against whatever rows are already in $MANIFEST.
run_manifest() {
  run env MK_GIT_BACKUP_MANIFEST="$MANIFEST" MK_GIT_BACKUP_NOTIFY="$NOTIFY" bash "$SCRIPT"
}

# The common case: a one-row manifest for WORK → ORIGIN with no ssh key.
run_backup() {
  printf '%s\t%s\t%s\n' "$WORK" "$ORIGIN" "" > "$MANIFEST"
  run_manifest
}

# Working dir already a repo wired to origin, with one pushed base commit.
seed_work() {
  local work="${1:-$WORK}" origin="${2:-$ORIGIN}"
  tgit clone -q "$origin" "$work" 2>/dev/null || { mkdir -p "$work"; tgit -C "$work" init -q; tgit -C "$work" remote add origin "$origin"; }
  printf 'base\n' > "$work/base.txt"
  tgit -C "$work" add -A
  tgit -C "$work" commit -q -m base
  tgit -C "$work" push -q -u origin HEAD
}

# Advance origin via a throwaway clone (simulates another writer / a web edit).
advance_origin() {
  local file="$1" content="$2" origin="${3:-$ORIGIN}" clone="$BATS_TEST_TMPDIR/other-$RANDOM"
  tgit clone -q "$origin" "$clone"
  printf '%s\n' "$content" > "$clone/$file"
  tgit -C "$clone" add -A
  tgit -C "$clone" commit -q -m "origin change"
  tgit -C "$clone" push -q origin HEAD
  rm -rf "$clone"
}

origin_has_file() {
  local file="$1" origin="${2:-$ORIGIN}" verify="$BATS_TEST_TMPDIR/verify-$RANDOM"
  tgit clone -q "$origin" "$verify"
  [ -f "$verify/$file" ]
}

# --- push::git (the git binary the whole script funnels through) ---

@test "routes git through MK_GIT_BACKUP_GIT with the baked machinekit identity" {
  seed_work
  printf 'change\n' > "$WORK/change.txt"
  # A wrapper that records its argv, then forwards to the real git so the backup
  # still completes. If the script ignored MK_GIT_BACKUP_GIT, the log never appears.
  local fakegit="$BATS_TEST_TMPDIR/fakegit"
  cat > "$fakegit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/git.argv"
exec git "\$@"
EOF
  chmod +x "$fakegit"
  printf '%s\t%s\t%s\n' "$WORK" "$ORIGIN" "" > "$MANIFEST"
  run env MK_GIT_BACKUP_MANIFEST="$MANIFEST" MK_GIT_BACKUP_NOTIFY="$NOTIFY" \
    MK_GIT_BACKUP_GIT="$fakegit" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/git.argv" ]
  grep -q -- '-c user.name=machinekit -c user.email=machinekit@localhost' "$BATS_TEST_TMPDIR/git.argv"
}

# --- first push (initializes a non-repo dir) ---

@test "initializes a fresh dir and makes the first push" {
  mkdir -p "$WORK"
  printf 'hello\n' > "$WORK/AGENTS.md"
  run_backup
  [ "$status" -eq 0 ]
  [ -d "$WORK/.git" ]
  origin_has_file AGENTS.md
}

# --- steady state ---

@test "fast-forwards local changes to origin" {
  seed_work
  printf 'new\n' > "$WORK/new.txt"
  run_backup
  [ "$status" -eq 0 ]
  origin_has_file new.txt
}

@test "is a clean no-op when there is nothing to push" {
  seed_work
  run_backup
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

# --- divergence ---

@test "rebases cleanly when origin diverged on a different file" {
  seed_work
  advance_origin origin.txt "from origin"
  printf 'local\n' > "$WORK/local.txt"
  run_backup
  [ "$status" -eq 0 ]
  origin_has_file local.txt
  origin_has_file origin.txt
}

@test "aborts and notifies when origin diverged with a conflicting change" {
  seed_work
  advance_origin base.txt "origin version"
  printf 'local version\n' > "$WORK/base.txt"
  run_backup
  [ "$status" -ne 0 ]
  grep -q "diverged and rebase conflicted" "$NOTIFY_LOG"
  # local change must remain (never silently merged/discarded)
  grep -q "local version" "$WORK/base.txt"
}

@test "leaves origin untouched after a conflict abort" {
  seed_work
  advance_origin base.txt "origin version"
  printf 'local version\n' > "$WORK/base.txt"
  run_backup
  local verify="$BATS_TEST_TMPDIR/verify"
  tgit clone -q "$ORIGIN" "$verify"
  grep -q "origin version" "$verify/base.txt"
}

# --- missing dir ---

@test "fails and notifies when a folder dir does not exist" {
  printf '%s\t%s\t%s\n' "$BATS_TEST_TMPDIR/absent" "$ORIGIN" "" > "$MANIFEST"
  run_manifest
  [ "$status" -ne 0 ]
  grep -q "dir not found" "$NOTIFY_LOG"
}

# --- multiple folders ---

@test "backs up every folder in the manifest" {
  local work2="$BATS_TEST_TMPDIR/work2" origin2="$BATS_TEST_TMPDIR/origin2.git"
  git init --bare -q "$origin2"
  mkdir -p "$WORK"; printf 'a\n' > "$WORK/a.txt"
  mkdir -p "$work2"; printf 'b\n' > "$work2/b.txt"
  printf '%s\t%s\t\n%s\t%s\t\n' "$WORK" "$ORIGIN" "$work2" "$origin2" > "$MANIFEST"
  run_manifest
  [ "$status" -eq 0 ]
  origin_has_file a.txt "$ORIGIN"
  origin_has_file b.txt "$origin2"
}

@test "isolates a failing folder: the others still back up and the run exits non-zero" {
  local work2="$BATS_TEST_TMPDIR/work2" origin2="$BATS_TEST_TMPDIR/origin2.git"
  git init --bare -q "$origin2"
  mkdir -p "$work2"; printf 'b\n' > "$work2/b.txt"
  # First row's dir is absent (fails); second row is a healthy backup.
  printf '%s\t%s\t\n%s\t%s\t\n' "$BATS_TEST_TMPDIR/absent" "$ORIGIN" "$work2" "$origin2" > "$MANIFEST"
  run_manifest
  [ "$status" -ne 0 ]
  grep -q "dir not found" "$NOTIFY_LOG"
  origin_has_file b.txt "$origin2"
}
