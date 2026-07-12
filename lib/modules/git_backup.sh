#!/usr/bin/env bash
# git_backup — periodically pushes one or more working dirs to git remotes, giving
# a live, replicated dir (e.g. one Syncthing keeps in sync — which propagates
# deletions and so is not itself a backup) durable history on a remote. Generic:
# it backs up whatever folders the blueprint lists ([[module.git_backup.folders]])
# and knows nothing about what lives in them. Depends on no other module.
#
# One service runs for all folders; the push script (git_backup/push.sh) iterates
# a manifest this module writes. Each folder is single-writer — back a given folder
# up from exactly one machine, or the machines race its one downstream branch.
#
# A folder may name an `ssh_key` (module-level default, per-folder override): a
# named secret (git_backup/ssh_keys/<name>) resolved via secrets::resolve — an
# age-encrypted pool file or a secrets-manager reference, whichever backend
# actually holds it — which the install writes out to a private key file the
# push uses. Omit it to push over ambient SSH (an agent or an on-disk default
# key).
#
# The scheduled-service mechanics — launchd/systemd unit generation and load —
# live in lib/machinekit/service.sh; git_backup hands it the push script, interval,
# and pinned environment. Manifest writing, key handling, and orchestration are
# tested here.

_GIT_BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ssh keys are named secrets, namespaced by service then key name:
# git_backup/ssh_keys/<name>. Resolved via secrets::resolve — this module
# never knows or cares whether that name is an age-encrypted pool file or a
# secrets-manager reference.
_GIT_BACKUP_SECRET_NAMESPACE="git_backup/ssh_keys"

# Depends on whichever backend(s) resolve the referenced keys: age for pool-file
# keys, secrets_manager for explicitly-referenced ones (a blueprint may mix both
# across keys). Derived from the declared secrets (declared_secrets), so a
# convention-backed key — resolved from an already-listed manager during
# preflight readiness — adds no edge, and ambient-SSH folders (no key, no
# secret) declare nothing.
git_backup::requires() {
  git_backup::declared_secrets | secrets::declared_backend_requirements
}

# Fail early on a misconfigured folder set, and remind that each folder is
# single-writer. No folders configured = nothing to validate.
git_backup::preflight() {
  local folders
  folders=$(git_backup::_folders)
  [ -n "$folders" ] || return 0
  git_backup::_validate_folders "$folders"
  git_backup::_validate_ignores "$folders"
  git_backup::_validate_keys
  logging::warn "git_backup: each folder is single-writer — back a given folder up from one machine only, or the machines race its downstream branch."
  return 0
}

# Declares each referenced ssh key as a required secret — the push can't
# decrypt a key that isn't there. A folder using ambient SSH references none.
git_backup::declared_secrets() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\ttrue\tfalse\n' "$(git_backup::_secret_name "$name")"
  done < <(git_backup::_referenced_key_names)
}

# Install the keys, write the manifest, lay down the push script, and schedule the
# one service that runs it. No folders = nothing to install.
git_backup::install() {
  logging::step "git_backup install"
  local folders
  folders=$(git_backup::_folders)
  if [ -z "$folders" ]; then
    logging::debug "git_backup: no folders configured; nothing to back up"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install the git-backup service (ssh keys, manifest, push script, $(git_backup::_interval)s timer)"
    return 0
  fi
  git_backup::_install_keys
  git_backup::_write_manifest
  git_backup::_apply_gitignores
  git_backup::_install_push_script
  git_backup::_install_service
  logging::success "git_backup: backup service installed."
}

# Each folder needs both a path and a remote; fail loudly on a malformed entry
# rather than writing a half-usable manifest.
git_backup::_validate_folders() {
  local folders="$1" bad
  bad=$(printf '%s' "$folders" | jq -r '
    any(.[]; (has("path")|not) or (has("remote")|not) or (.path == "") or (.remote == ""))')
  [ "$bad" = "true" ] && lifecycle::fail \
    "git_backup: every [[module.git_backup.folders]] entry needs both a path and a remote."
  return 0
}

# Each folder's ignore config must be coherent: refusing to manage .gitignore while
# still listing ignore_patterns is a contradiction; managing it with neither
# defaults nor patterns is a pointless empty block (warn, don't fail).
git_backup::_validate_ignores() {
  local folders="$1" folder path manage add_defaults pattern_count
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    path=$(printf '%s' "$folder" | jq -r '.path // "?"')
    manage=$(printf '%s' "$folder" | jq -r 'if .manage_gitignore == null then true else .manage_gitignore end')
    add_defaults=$(printf '%s' "$folder" | jq -r 'if .add_default_ignores == null then true else .add_default_ignores end')
    pattern_count=$(printf '%s' "$folder" | jq -r '(.ignore_patterns // []) | length')
    if [ "$manage" != "true" ] && [ "$pattern_count" -gt 0 ]; then
      lifecycle::fail "git_backup: folder '$path' sets manage_gitignore = false but lists ignore_patterns — drop one (machinekit can't both manage .gitignore and leave it alone)."
    fi
    if [ "$manage" = "true" ] && [ "$add_defaults" != "true" ] && [ "$pattern_count" -eq 0 ]; then
      logging::warn "git_backup: folder '$path' manages .gitignore with no defaults and no ignore_patterns — only an empty managed block will be written."
    fi
  done < <(printf '%s' "$folders" | jq -c '.[]')
  return 0
}

# Every referenced ssh_key must have its encrypted secret in the pool, or the
# decrypt at install would fail mid-run.
git_backup::_validate_keys() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    secrets::present "$(git_backup::_secret_name "$name")" || lifecycle::fail \
      "git_backup: ssh_key '$name' is configured but no secret named $(git_backup::_secret_name "$name") — see docs/modules.md (git_backup)."
  done < <(git_backup::_referenced_key_names)
  return 0
}

git_backup::_install_keys() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    git_backup::_install_key "$name"
  done < <(git_backup::_referenced_key_names)
}

# Resolve one named ssh key to a private (600) file under a private (700) dir,
# where the push reads it via GIT_SSH_COMMAND. secrets::install_secret_file does
# the atomic non-empty temp+rename (secrets::resolve may be a network fetch), so a
# failed or interrupted fetch never truncates the live key in place.
git_backup::_install_key() {
  local name="$1" secret_name key_path key_dir
  secret_name="$(git_backup::_secret_name "$name")"
  key_path=$(git_backup::_key_path "$name")
  key_dir=$(dirname "$key_path")
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  secrets::install_secret_file "$key_path" secrets::resolve "$secret_name" \
    || lifecycle::fail "git_backup: no value resolved for ssh key secret $secret_name."
}

# Write the manifest the push script iterates: one tab-separated row per folder.
git_backup::_write_manifest() {
  local manifest folders default_ssh_key folder
  manifest=$(git_backup::_manifest_path)
  mkdir -p "$(dirname "$manifest")"
  : > "$manifest"
  folders=$(git_backup::_folders)
  [ -n "$folders" ] || return 0
  default_ssh_key=$(git_backup::_default_ssh_key)
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    git_backup::_manifest_row "$folder" "$default_ssh_key" >> "$manifest"
  done < <(printf '%s' "$folders" | jq -c '.[]')
}

# One manifest row (path<TAB>remote<TAB>ssh_key_path) for a folder. ssh_key falls
# back to the module default; an empty name yields an empty key path (ambient SSH).
git_backup::_manifest_row() {
  local folder="$1" default_ssh_key="$2" path remote ssh_key_name ssh_key_path=""
  path=$(printf '%s' "$folder" | jq -r '.path')
  path=${path/#\~/$HOME}
  remote=$(printf '%s' "$folder" | jq -r '.remote')
  ssh_key_name=$(printf '%s' "$folder" | jq -r --arg default "$default_ssh_key" '.ssh_key // $default')
  [ -n "$ssh_key_name" ] && ssh_key_path=$(git_backup::_key_path "$ssh_key_name")
  printf '%s\t%s\t%s\n' "$path" "$remote" "$ssh_key_path"
}

git_backup::_apply_gitignores() {
  local folders folder path
  folders=$(git_backup::_folders)
  [ -n "$folders" ] || return 0
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    path=$(printf '%s' "$folder" | jq -r '.path')
    path=${path/#\~/$HOME}
    git_backup::_apply_gitignore "$folder" "$path"
  done < <(printf '%s' "$folders" | jq -c '.[]')
}

# Reconcile a folder's .gitignore — but only if the folder already exists, since
# git_backup must never create or populate a folder another module owns (an empty
# dir holding just a .gitignore reads as "present" and would block its seed).
# manage_gitignore = false leaves the file to the user.
git_backup::_apply_gitignore() {
  local folder="$1" path="$2"
  [ -d "$path" ] || return 0
  [ "$(printf '%s' "$folder" | jq -r 'if .manage_gitignore == null then true else .manage_gitignore end')" = "true" ] || return 0
  git_backup::_gitignore_patterns "$folder" | managed_block::ensure "$path/.gitignore" "#"
}

# Emit the folder's ordered, de-duplicated ignore lines: user ignore_patterns
# first, then the defaults unless add_default_ignores is false.
git_backup::_gitignore_patterns() {
  local folder="$1"
  {
    printf '%s' "$folder" | jq -r '.ignore_patterns[]? // empty'
    if [ "$(printf '%s' "$folder" | jq -r 'if .add_default_ignores == null then true else .add_default_ignores end')" = "true" ]; then
      git_backup::_default_ignores
    fi
  } | awk 'NF && !seen[$0]++'
}

# Junk a backup repo should never carry, including Syncthing's version buffer
# (.stversions/) — git would otherwise commit it.
git_backup::_default_ignores() {
  printf '%s\n' '.DS_Store' '._*' '.stversions/'
}

git_backup::_install_push_script() {
  local dest
  dest=$(git_backup::_push_script_path)
  mkdir -p "$(dirname "$dest")"
  cp "$_GIT_BACKUP_DIR/git_backup/push.sh" "$dest"
  chmod 755 "$dest"
}

# Schedule the one service that runs the push script for every folder, pinning the
# manifest, notify command, and absolute git path into its environment. The push
# script is a self-contained executable, so service::install_interval runs it
# directly (its shebang picks the interpreter); the launchd/systemd split is
# service.sh's job.
git_backup::_install_service() {
  service::install_interval \
    git-backup \
    "$(git_backup::_push_script_path)" \
    "$(git_backup::_interval)" \
    "MK_GIT_BACKUP_MANIFEST=$(git_backup::_manifest_path)" \
    "MK_GIT_BACKUP_NOTIFY=$(git_backup::_notify)" \
    "MK_GIT_BACKUP_GIT=$(git_backup::_git_path)"
}

# --- config accessors + paths ---

# Array-of-tables; `|| true` so an unset key is an empty result (no folders is a
# valid no-op config), not a set -e failure.
git_backup::_folders() {
  config::get "module.git_backup.folders" || true
}

git_backup::_interval() {
  config::get "module.git_backup.interval" --default 300
}

# Optional notify command; empty lets the push script fall back to logger/journald.
git_backup::_notify() {
  config::get "module.git_backup.notify" --default ""
}

# The git binary the service unit pins into push.sh's environment. machinekit
# installs git as a prerequisite, so apply's PATH (brew-prepended) resolves to it;
# the detached daemon's minimal PATH would not, hence pinning the absolute path
# rather than trusting whatever git the machine may or may not carry.
git_backup::_git_path() {
  command -v git
}

# Module-level default ssh_key name; a folder may override it. Empty = ambient SSH.
git_backup::_default_ssh_key() {
  config::get "module.git_backup.ssh_key" --default ""
}

# Distinct ssh_key names the folder set references (folder override or module
# default), one per line, empties dropped. The single source for which keys to
# decrypt, validate, and require age for.
git_backup::_referenced_key_names() {
  local folders default_ssh_key
  folders=$(git_backup::_folders)
  [ -n "$folders" ] || return 0
  default_ssh_key=$(git_backup::_default_ssh_key)
  printf '%s' "$folders" \
    | jq -r --arg default "$default_ssh_key" '.[] | (.ssh_key // $default) | select(. != "")' \
    | sort -u
}

# The bare logical secret name for a key name — the single source of it; every
# other function asks secrets::resolve/present/backend_for for the rest.
git_backup::_secret_name() {
  printf '%s/%s\n' "$_GIT_BACKUP_SECRET_NAMESPACE" "$1"
}

git_backup::_key_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/machinekit/git_backup/ssh_keys/$1"
}

git_backup::_manifest_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/git_backup/manifest.tsv"
}

git_backup::_push_script_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/git_backup/push.sh"
}
