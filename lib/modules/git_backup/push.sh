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
# arrived another way (e.g. synced in) may not be, so initialize idempotently.
push::ensure_repo() {
  local remote="$1"
  [ -d .git ] || push::git init -q
  if push::git remote get-url origin >/dev/null 2>&1; then
    push::git remote set-url origin "$remote"
  else
    push::git remote add origin "$remote"
  fi
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
  [ -n "$ssh_key" ] && export GIT_SSH_COMMAND="ssh -i $ssh_key -o IdentitiesOnly=yes"
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
