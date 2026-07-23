#!/usr/bin/env bash
# Periodic push-only-with-abort git backup of one or more working dirs. git_backup
# installs this and schedules it on a service unit; it runs out-of-band, so it
# depends on nothing but git and is self-contained (it sources no machinekit
# library).
#
# Each folder is single-writer by contract: exactly one machine should back a
# given folder up. The remote is treated as downstream-only — the 99% path is
# fetch + fast-forward push. On an unexpected divergence it rebases; if that
# conflicts it aborts and notifies, leaving local and remote untouched rather than
# fanning a bad merge out to whatever replicates the dir.
#
# Folders come from a tab-separated manifest, one row per folder:
#   <path>\t<remote>\t<ssh_key_path>   (empty ssh_key_path = use ambient SSH)
# A folder's failure is notified and the run moves on to the next; the script
# exits non-zero if any folder failed.
#
# Config via env:
#   MK_GIT_BACKUP_MANIFEST  the manifest file (rows as above); required
#   MK_GIT_BACKUP_NOTIFY    command run with one message arg on trouble; optional
#                           (default: logger -t machinekit-git-backup)
#   MK_GIT_BACKUP_GIT       the git binary to use; optional (default: git on PATH).
#                           The service unit pins this to the git machinekit
#                           installed, since the daemon's minimal PATH excludes it.
set -euo pipefail

# Identity baked in so the headless service needs no global git config. The git
# binary is taken from MK_GIT_BACKUP_GIT (the unit pins our installed git, since
# the daemon's minimal PATH won't find it) and falls back to PATH for manual runs.
push::git() {
  "${MK_GIT_BACKUP_GIT:-git}" -c user.name=machinekit -c user.email=machinekit@localhost "$@"
}

push::notify() {
  local message="$1"
  if [ -n "${MK_GIT_BACKUP_NOTIFY:-}" ]; then
    "$MK_GIT_BACKUP_NOTIFY" "$message" || true
  else
    logger -t machinekit-git-backup "$message" 2>/dev/null || printf '%s\n' "$message" >&2
  fi
}

# Notify and exit. Called only inside a per-folder subshell (see push::main), so it
# ends that one folder's backup without aborting the rest of the run.
push::fail() {
  push::notify "$1"
  exit 1
}

# Make the dir a repo pointed at the remote. Cloned dirs already are; a dir that
# arrived another way — synced in, or seeded then stripped of its .git — is not, so
# initialize idempotently. A freshly-initialized repo must then anchor onto origin's
# history before anything commits (see push::anchor_to_origin).
push::ensure_repo() {
  local remote="$1" fresh=0
  if [ ! -d .git ]; then
    push::git init -q
    fresh=1
  fi
  if push::git remote get-url origin >/dev/null 2>&1; then
    push::git remote set-url origin "$remote"
  else
    push::git remote add origin "$remote"
  fi
  if [ "$fresh" -eq 1 ]; then
    push::anchor_to_origin
  fi
}

# Anchor a freshly-initialized repo onto origin's history so its first commit is a
# descendant, not a root sharing no ancestry (which every push would add/add-conflict
# on — seen with a stripped dir carrying a pending edit, or a backup machine rebuilt
# from a mesh that ran ahead of origin). Move HEAD onto origin's branch *by name* —
# the local init.defaultBranch need not match the branch origin's history lives on —
# then reset --mixed onto it: index reset to origin, working tree untouched, so
# commit_local records real diffs on top. No reachable origin branch yet (first-ever
# backup) → leave the fresh init alone; push takes the initial-push path.
push::anchor_to_origin() {
  local branch
  branch=$(push::origin_head_branch) || return 0
  push::git fetch -q origin "$branch" 2>/dev/null || return 0
  push::git rev-parse --verify -q "origin/$branch" >/dev/null || return 0
  push::git symbolic-ref HEAD "refs/heads/$branch"
  push::git reset --mixed -q "origin/$branch"
  push::restore_origin_only_files
}

# After the index is anchored to origin, the working tree still lacks any file that
# exists on origin but not in the seeded/synced content — an external writer's commit
# this machine hasn't received yet. Left alone, commit_local's `git add -A` reads
# those as deletions and the backup silently drops them from origin. Restore just
# those files (index → working tree), so the reconstituted commit is origin's content
# overlaid with local changes, never a deletion of origin-only files. Files the
# working tree actually modified are not "deleted", so they're left as-is — the local
# edit still wins; working-tree-only files stay as additions.
push::restore_origin_only_files() {
  push::git ls-files -z --deleted | while IFS= read -r -d '' path; do
    push::git checkout -q -- "$path"
  done
}

# Origin's default branch, read from its HEAD symref. The authority for which branch
# origin's history lives on is origin itself — not the local init.defaultBranch, which
# a headless machine (no global git config) leaves at git's compiled-in default.
# Nonzero when origin is unreachable or has no branches yet.
push::origin_head_branch() {
  local branch
  branch=$(push::git ls-remote --symref origin HEAD 2>/dev/null \
    | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }')
  [ -n "$branch" ] || return 1
  printf '%s\n' "$branch"
}

push::current_branch() {
  push::git symbolic-ref --short HEAD 2>/dev/null || printf 'main\n'
}

# Stage and commit everything, skipping cleanly when there's nothing new.
push::commit_local() {
  push::git add -A
  if push::git diff --cached --quiet; then
    return 0
  fi
  push::git commit -q -m "git_backup: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# The push-only-with-abort core.
push::push() {
  local branch
  branch=$(push::current_branch)
  push::git fetch -q origin "$branch" 2>/dev/null || true

  if ! push::git rev-parse "origin/$branch" >/dev/null 2>&1; then
    push::git push -q -u origin "$branch" || push::fail "git_backup: initial push failed ($(pwd))."
    return 0
  fi

  if push::git merge-base --is-ancestor "origin/$branch" HEAD; then
    # Origin is an ancestor of HEAD → fast-forward; nothing to reconcile.
    push::git push -q origin "$branch" || push::fail "git_backup: push failed ($(pwd); network/auth?)."
    return 0
  fi

  # Diverged: origin carries commits we don't. Rebase onto it; abort + notify on
  # conflict, leaving both sides untouched rather than fanning a bad merge out.
  if push::git pull -q --rebase origin "$branch"; then
    push::git push -q origin "$branch" || push::fail "git_backup: push after rebase failed ($(pwd))."
  else
    push::git rebase --abort 2>/dev/null || true
    push::fail "git_backup: $(pwd) diverged and rebase conflicted; left untouched. Resolve manually."
  fi
}

# Back up a single folder. Runs entirely within a subshell (see push::main) so the
# cd, the per-folder GIT_SSH_COMMAND, and any push::fail all stay scoped to this
# one folder.
push::backup_folder() {
  local path="$1" remote="$2" ssh_key="$3"
  cd "$path" 2>/dev/null || push::fail "git_backup: dir not found: $path"
  # accept-new auto-trusts an unknown host key on first contact (the daemon has no
  # TTY to answer StrictHostKeyChecking=ask) while still refusing a changed key.
  [ -n "$ssh_key" ] && export GIT_SSH_COMMAND="ssh -i $ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  push::ensure_repo "$remote"
  push::commit_local
  push::push
}

# Iterate the manifest, backing each folder up in isolation. A folder's failure is
# notified inside its subshell and the loop continues; the run exits non-zero if
# any folder failed, so the service log records the trouble.
push::main() {
  local manifest="${MK_GIT_BACKUP_MANIFEST:?MK_GIT_BACKUP_MANIFEST required}"
  local path remote ssh_key failures=0
  while IFS=$'\t' read -r path remote ssh_key; do
    [ -n "$path" ] || continue
    ( push::backup_folder "$path" "$remote" "$ssh_key" ) || failures=$((failures + 1))
  done < "$manifest"
  [ "$failures" -eq 0 ] || exit 1
}

# Run only when executed, not when sourced (so tests can exercise functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  push::main "$@"
fi
