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
  ARGV_LOG="$BATS_TEST_TMPDIR/git.argv"
  SSH_LOG="$BATS_TEST_TMPDIR/git.ssh"
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

# Back up WORK → ORIGIN with the given ssh_key column ("" for none), under a git
# that records both its argv and the GIT_SSH_COMMAND it inherits, then forwards to
# real git so the backup still completes. One run thus exposes both how the script
# invokes git (the baked identity in ARGV_LOG) and the ssh command it exports for
# the folder (host-key policy / key in SSH_LOG). The remote is a local path, so git
# never actually invokes ssh — but the script exports the command for every git
# call, so SSH_LOG captures exactly what an ssh push would have used.
#
# ARGV accumulates every call one per line (the invocations differ, and the per-line
# record is what lets a test assert the identity rides every one); the ssh command is
# constant for the folder, so it overwrites to the one value in effect — exact-
# matchable, and left empty when no key sets it.
run_recorded_backup() {
  local ssh_key="$1" fakegit="$BATS_TEST_TMPDIR/fakegit"
  cat > "$fakegit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
printf '%s' "\${GIT_SSH_COMMAND:-}" > "$SSH_LOG"
exec git "\$@"
EOF
  chmod +x "$fakegit"
  printf '%s\t%s\t%s\n' "$WORK" "$ORIGIN" "$ssh_key" > "$MANIFEST"
  run env MK_GIT_BACKUP_MANIFEST="$MANIFEST" MK_GIT_BACKUP_NOTIFY="$NOTIFY" \
    MK_GIT_BACKUP_GIT="$fakegit" bash "$SCRIPT"
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

@test "with no key: bakes the machinekit identity into git and leaves ssh at its default" {
  seed_work
  printf 'change\n' > "$WORK/change.txt"
  run_recorded_backup ""
  [ "$status" -eq 0 ]
  run ! grep -qvE -- '-c user.name=machinekit -c user.email=machinekit@localhost' "$ARGV_LOG"
  # No key → the script never sets GIT_SSH_COMMAND, so nothing is recorded and the
  # log stays empty; git uses its default ssh.
  [ ! -s "$SSH_LOG" ]
}

@test "with a key: keeps the baked identity and drives git over the key with accept-new" {
  seed_work
  printf 'change\n' > "$WORK/change.txt"
  local key="$BATS_TEST_TMPDIR/id_backup"
  run_recorded_backup "$key"
  [ "$status" -eq 0 ]
  # Same baked identity as the no-key case — it's independent of the ssh key.
  run ! grep -qvE -- '-c user.name=machinekit -c user.email=machinekit@localhost' "$ARGV_LOG"
  # Plus a GIT_SSH_COMMAND pinning the key and trusting an unknown host on first
  # contact (the daemon has no TTY to answer StrictHostKeyChecking=ask). Exact, so a
  # stray extra option would fail rather than slip past a substring match.
  [ "$(cat "$SSH_LOG")" = "ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" ]
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

# --- reconstitution (.git stripped, e.g. by agents_config_setup) ---

@test "reconstitutes a .git-deleted dir onto origin, committing a pending edit as a descendant" {
  seed_work
  rm -rf "$WORK/.git"                     # agents_config_setup stripped it
  printf 'edited\n' > "$WORK/base.txt"    # a pending edit: working tree ahead of origin
  run_backup
  # Anchored to origin's history, so the edit commits on top of it rather than as an
  # unrelated root that add/add-conflicts (which is what the old bare `git init` did).
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
  origin_has_file base.txt
  local verify="$BATS_TEST_TMPDIR/verify-rec"
  tgit clone -q "$ORIGIN" "$verify"
  grep -q "edited" "$verify/base.txt"
  # Linear history: origin's base commit, then the backup commit — not an orphan root.
  [ "$(tgit -C "$verify" rev-list --count HEAD)" -eq 2 ]
}

@test "reconstitution preserves origin files the working tree lacks (no clobber)" {
  # The working tree is BEHIND origin: an external writer pushed external.txt to
  # origin, but this machine's (stripped) content predates it. The backup must
  # commit the local edit as a descendant WITHOUT deleting origin's external.txt —
  # reset --mixed leaves the working tree missing that file, so a naive `add -A`
  # would stage its deletion and fast-forward it away.
  seed_work
  advance_origin external.txt "from-elsewhere"   # another writer adds a file to origin
  rm -rf "$WORK/.git"                             # stripped; WORK still lacks external.txt
  printf 'edited\n' > "$WORK/base.txt"            # a local edit
  run_backup
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
  local verify="$BATS_TEST_TMPDIR/verify-noclobber"
  tgit clone -q "$ORIGIN" "$verify"
  grep -q "edited" "$verify/base.txt"             # the local edit landed
  grep -q "from-elsewhere" "$verify/external.txt" # origin's external file was NOT clobbered
}

@test "anchors onto origin's branch even when the local init default differs" {
  # Origin's history lives on main; the reconstituting machine's fresh `git init`
  # defaults to master (forced here, independent of the host's ambient default). The
  # anchor must resolve origin's actual branch, not the local init default — otherwise
  # it commits an orphan master root and pushes it as a divergent branch, never
  # advancing origin's main.
  local origin_main="$BATS_TEST_TMPDIR/origin-main.git"
  git init --bare -b main -q "$origin_main"
  local seed="$BATS_TEST_TMPDIR/seed-main"
  tgit clone -q "$origin_main" "$seed" 2>/dev/null
  printf 'base\n' > "$seed/base.txt"
  tgit -C "$seed" add -A
  tgit -C "$seed" commit -q -m base
  tgit -C "$seed" push -q -u origin main

  mkdir -p "$WORK"                        # a stripped content dir: no .git
  printf 'edited\n' > "$WORK/base.txt"    # a pending edit ahead of origin

  # Force the script's fresh `git init` to master regardless of the host default, and
  # neutralize system config so the mismatch with origin's main is guaranteed.
  local master_config="$BATS_TEST_TMPDIR/gitconfig-master"
  printf '[init]\n\tdefaultBranch = master\n' > "$master_config"
  printf '%s\t%s\t%s\n' "$WORK" "$origin_main" "" > "$MANIFEST"
  run env MK_GIT_BACKUP_MANIFEST="$MANIFEST" MK_GIT_BACKUP_NOTIFY="$NOTIFY" \
    GIT_CONFIG_GLOBAL="$master_config" GIT_CONFIG_SYSTEM=/dev/null bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
  # Origin's main advanced with the edit as a descendant — 2 commits, no orphan.
  local verify="$BATS_TEST_TMPDIR/verify-branch"
  tgit clone -q "$origin_main" "$verify"
  grep -q "edited" "$verify/base.txt"
  [ "$(tgit -C "$verify" rev-list --count main)" -eq 2 ]
  # No stray master branch was pushed to origin.
  [ -z "$(git -C "$origin_main" for-each-ref --format='%(refname:short)' refs/heads/master)" ]
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
