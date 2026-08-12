#!/usr/bin/env bash
# offsite_backup — periodically copies configured local paths to remote restic
# repositories. Deliberately generic: it backs up whatever paths the blueprint
# lists and knows nothing about what produced the files or what else replicates
# them. Depends on no other module.
#
# restic, not a plain object-store sync, because three of its properties are the
# point: retention declared in the blueprint rather than in a provider console,
# mandatory client-side encryption keyed by one repository password (so the
# off-fleet copy hands the provider ciphertext, and there is no new key type to
# keep alive), and a check that actually verifies the remote. Deduplication —
# restic's headline feature — is irrelevant here and deliberately not designed for.
#
# A blueprint declares one or more repositories, each with its own paths:
#
#   [[module.offsite_backup.repositories]]
#   name = "b2"
#   repository = "s3:…"
#   [[module.offsite_backup.repositories.paths]]
#   path = "~/postgres-dumps"
#
# Several paths in ONE repository is the common shape and needs no nesting:
# restic groups snapshots by host and paths when forgetting, so each path gets
# the keep policy applied to it independently, and deduplication is shared across
# the whole repository. A second repository is for what a second entry in the same
# one cannot express — a different destination, a different encryption key, or a
# different keep policy (restic's --keep-* are scalars on one forget invocation).
#
# Everything except the destination and its paths has a module-level default that
# a repository may override, so the single-repository case stays flat.
#
# Two secrets per repository, named offsite_backup/<name>/* and resolved via
# secrets::resolve (an age-encrypted pool file or a secrets-manager reference):
# the repository password, and the backend's credentials as opaque KEY=value
# lines. Credentials are opaque because every restic backend reads different
# variable names, and modelling them per provider is what would make this module
# provider-specific. The service units pin the secret *paths*, never their values
# — a launchd plist is readable at rest.
#
# Each repository gets two services from the one installed script: the frequent
# backup-and-prune, and a rarer repository check (verification is the expensive
# part, so it gets its own cadence rather than riding every run). Which job a unit
# runs is pinned in its environment, because the scheduler primitive takes an
# executable and no arguments.
#
# Creating a repository writes to the remote, so it is consent-gated: an
# interactive yes, or MACHINEKIT_OFFSITE_BACKUP_INIT_REPOSITORY=1 unattended.
# Consent is only sought for a repository that is actually absent, so a routine
# re-apply never asks. Without it the install completes and the services are
# scheduled — they just fail until the repository exists, which postflight says.

_OFFSITE_BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Secrets are namespaced by service then repository, like git_backup's ssh keys:
# this module never knows or cares whether a name resolves from an age pool file
# or a manager.
_OFFSITE_BACKUP_SECRET_NAMESPACE="offsite_backup"

_OFFSITE_BACKUP_DEFAULT_SCHEDULE="30 3 * * *"
_OFFSITE_BACKUP_DEFAULT_CHECK_SCHEDULE="0 4 * * 0"

# A keep policy ships by default because the alternative is unbounded growth: each
# run adds a full new copy, so with no retention a repository grows with the
# square of time. postflight_info prints whatever is in force, since retention is
# what deletes remote history.
_OFFSITE_BACKUP_DEFAULT_KEEP_DAILY="7"
_OFFSITE_BACKUP_DEFAULT_KEEP_WEEKLY="4"
_OFFSITE_BACKUP_DEFAULT_KEEP_MONTHLY="12"

# Depends on whichever backend(s) resolve this module's secrets: age for pool
# files, secrets_manager for explicitly-referenced ones. Derived from the declared
# secrets, which are themselves empty when no repositories are configured — so an
# activated-but-unconfigured module adds no edge.
offsite_backup::requires() {
  offsite_backup::declared_secrets | secrets::declared_backend_requirements
}

# Two secrets per repository. The password is mandatory — restic cannot open a
# repository without it — and neither is one machinekit could generate: the
# password must match whatever the repository was created with, and the
# credentials belong to the operator's provider account. Backend credentials are
# optional, since a local or sftp repository needs none.
offsite_backup::declared_secrets() {
  local repositories name
  repositories=$(offsite_backup::_repositories)
  [ -n "$repositories" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\ttrue\tfalse\n'  "$(offsite_backup::_secret_name "$name" repository_password)"
    printf '%s\tfalse\tfalse\n' "$(offsite_backup::_secret_name "$name" credentials)"
  done < <(printf '%s' "$repositories" | jq -r '.[].name // empty')
}

# Fail early on a misconfigured repository set rather than partway through
# install — or, worse, silently at 3am. No repositories = nothing to validate.
offsite_backup::preflight() {
  local repositories entry
  repositories=$(offsite_backup::_repositories)
  [ -n "$repositories" ] || return 0
  offsite_backup::_validate_repositories "$repositories"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    offsite_backup::_validate_repository "$entry"
  done < <(printf '%s' "$repositories" | jq -c '.[]')
}

# Everything about one repository that can be wrong independently of the set:
# its paths, the secret that opens it, and its two schedules.
offsite_backup::_validate_repository() {
  local entry="$1"
  offsite_backup::_validate_paths "$(offsite_backup::_paths "$entry")"
  offsite_backup::_validate_secrets "$(offsite_backup::_name "$entry")"
  service::validate_cron "$(offsite_backup::_schedule "$entry")"
  service::validate_cron "$(offsite_backup::_check_schedule "$entry")"
}

# Install restic and the run script once, then wire each repository. No
# repositories = nothing to install, not even restic.
offsite_backup::install() {
  logging::step "offsite_backup install"
  local repositories entry
  repositories=$(offsite_backup::_repositories)
  if [ -z "$repositories" ]; then
    logging::debug "offsite_backup: no repositories configured; nothing to back up"
    return 0
  fi
  brew::install_formula restic
  if input::is_dry_run; then
    logging::dry_run "would install the offsite-backup services for each configured repository (secret files, manifests, run script, schedules), and offer to create any that do not exist yet"
    return 0
  fi
  # One script serves every repository — the per-repository differences all live
  # in the service units' environment — so it is laid down once, and before any
  # repository, since the create step drives it.
  offsite_backup::_install_run_script
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    offsite_backup::_install_repository "$entry"
  done < <(printf '%s' "$repositories" | jq -c '.[]')
  logging::success "offsite_backup: backup and check services installed."
}

offsite_backup::_install_repository() {
  local entry="$1" name
  name=$(offsite_backup::_name "$entry")
  # Order is the contract: creating the repository drives the run script with
  # this repository's secret files, so those must be on disk first.
  offsite_backup::_install_secret_files "$name"
  offsite_backup::_write_manifest "$name" "$(offsite_backup::_paths "$entry")"
  offsite_backup::_ensure_repository "$entry"
  offsite_backup::_install_backup_service "$entry"
  offsite_backup::_install_check_service "$entry"
}

# postflight: what leaves this machine, where to, and — because it is what deletes
# remote history — the retention actually in force for each destination.
offsite_backup::postflight_info() {
  local repositories entry name repository path
  repositories=$(offsite_backup::_repositories)
  [ -n "$repositories" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=$(offsite_backup::_name "$entry")
    repository=$(offsite_backup::_repository "$entry")
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf 'Backing up %s to %s (%s) on schedule "%s".\n' \
        "$path" "$name" "$repository" "$(offsite_backup::_schedule "$entry")"
    done < <(printf '%s' "$entry" | jq -r '.paths[]?.path // empty')
    printf 'Repository %s: keeping %s daily, %s weekly, %s monthly snapshots; verified on schedule "%s".\n' \
      "$name" \
      "$(offsite_backup::_keep_daily "$entry")" \
      "$(offsite_backup::_keep_weekly "$entry")" \
      "$(offsite_backup::_keep_monthly "$entry")" \
      "$(offsite_backup::_check_schedule "$entry")"
  done < <(printf '%s' "$repositories" | jq -c '.[]')
}

# postflight: the step still on the operator, named per repository and only when
# there is one. An unconsented apply leaves a repository uncreated, and its
# scheduled runs fail until it exists — so say so rather than letting it surface
# at 3am.
offsite_backup::postflight_instructions() {
  local repositories entry
  repositories=$(offsite_backup::_repositories)
  [ -n "$repositories" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$(offsite_backup::_repository_ready "$(offsite_backup::_name "$entry")")" = "true" ] && continue
    printf 'The restic repository %s does not exist yet — re-apply with MACHINEKIT_OFFSITE_BACKUP_INIT_REPOSITORY=1 to create it, or run restic init yourself (see docs/modules.md).\n' \
      "$(offsite_backup::_repository "$entry")"
  done < <(printf '%s' "$repositories" | jq -c '.[]')
}

offsite_backup::_validate_repositories() {
  local shape_error
  shape_error="$(offsite_backup::_repositories_shape_error "$1")"
  [ -z "$shape_error" ] || lifecycle::fail "offsite_backup: $shape_error"
}

# Pure shape check on the repository set; echoes the first problem found (empty =
# valid). The name rule is strict because the name becomes a secret namespace, a
# filename, a service label, and part of an environment-variable name — anything
# outside [a-z0-9_] breaks one of those somewhere downstream instead of here.
offsite_backup::_repositories_shape_error() {
  printf '%s' "$1" | jq -r '
    if   any(.[]; (.name // "") == "") then
      "every [[module.offsite_backup.repositories]] entry needs a name"
    elif any(.[]; ((.name | tostring) | test("^[a-z0-9_]+$") | not)) then
      "a repository name must be lowercase letters, digits, and underscores (it names secrets, files, and service units)"
    elif ([.[].name] | length) != ([.[].name] | unique | length) then
      "a repository name appears more than once"
    elif any(.[]; (.repository // "") == "") then
      "every repository entry needs a repository string (e.g. s3:…)"
    elif any(.[]; ((.paths // []) | length) == 0) then
      "every repository needs at least one [[module.offsite_backup.repositories.paths]] entry"
    else empty end'
}

# Every path entry needs a path, and a staleness deadline (when given) has to be a
# number of hours; fail loudly rather than writing a half-usable manifest.
offsite_backup::_validate_paths() {
  local paths="$1" shape_error
  shape_error=$(printf '%s' "$paths" | jq -r '
    if   any(.[]; (.path // "") == "") then
      "every [[module.offsite_backup.repositories.paths]] entry needs a path"
    elif any(.[]; (.max_age_hours != null) and ((.max_age_hours | tostring | test("^[0-9]+$")) | not)) then
      "max_age_hours must be a whole number of hours"
    else empty end')
  [ -z "$shape_error" ] || lifecycle::fail "offsite_backup: $shape_error"
}

# Only the password is required. The credentials secret is optional, and whether a
# given backend needs one is the operator's business, not something this module
# can know.
offsite_backup::_validate_secrets() {
  local name="$1" password_secret
  password_secret=$(offsite_backup::_secret_name "$name" repository_password)
  secrets::present "$password_secret" || lifecycle::fail \
    "offsite_backup: no secret named $password_secret — restic cannot open the repository without its password. See docs/modules.md (offsite_backup)."
}

offsite_backup::_install_secret_files() {
  local name="$1" password_secret credentials_secret
  password_secret=$(offsite_backup::_secret_name "$name" repository_password)
  offsite_backup::_write_secret_file "$(offsite_backup::_password_file_path "$name")" "$password_secret" \
    || lifecycle::fail "offsite_backup: no value resolved for the repository password secret $password_secret."
  credentials_secret=$(offsite_backup::_secret_name "$name" credentials)
  secrets::present "$credentials_secret" || return 0
  offsite_backup::_write_secret_file "$(offsite_backup::_credentials_file_path "$name")" "$credentials_secret" \
    || lifecycle::fail "offsite_backup: the credentials secret $credentials_secret is declared but resolved to nothing."
}

# Resolve one named secret to a private (600) file under a private (700) dir,
# where the run script reads it. secrets::install_secret_file does the atomic
# non-empty temp+rename (secrets::resolve may be a network fetch), so a failed or
# interrupted fetch never truncates the live file in place.
offsite_backup::_write_secret_file() {
  local dest="$1" secret_name="$2" dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  chmod 700 "$dir"
  secrets::install_secret_file "$dest" secrets::resolve "$secret_name"
}

# Write the manifest one repository's backup run iterates: one tab-separated row
# per path.
offsite_backup::_write_manifest() {
  local name="$1" paths="$2" manifest entry
  manifest=$(offsite_backup::_manifest_path "$name")
  mkdir -p "$(dirname "$manifest")"
  : > "$manifest"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    offsite_backup::_manifest_row "$entry" >> "$manifest"
  done < <(printf '%s' "$paths" | jq -c '.[]')
}

# One manifest row (path<TAB>max_age_hours). An absent deadline stays empty; the
# run script reads that as "no staleness check for this path".
offsite_backup::_manifest_row() {
  local entry="$1" path max_age_hours
  path=$(printf '%s' "$entry" | jq -r '.path')
  path=${path/#\~/$HOME}
  max_age_hours=$(printf '%s' "$entry" | jq -r '.max_age_hours // ""')
  printf '%s\t%s\n' "$path" "$max_age_hours"
}

offsite_backup::_install_run_script() {
  local dest
  dest=$(offsite_backup::_run_script_path)
  mkdir -p "$(dirname "$dest")"
  cp "$_OFFSITE_BACKUP_DIR/offsite_backup/restic_run.sh" "$dest"
  chmod 755 "$dest"
}

# Make sure there is a repository to back up into. Creating one writes to the
# remote, so it is consent-gated like every other outward act — but only asked
# for when there is nothing there, which keeps a routine re-apply silent. The
# outcome is recorded so postflight can report the gap without re-probing (or
# re-prompting).
offsite_backup::_ensure_repository() {
  local entry="$1" name
  name=$(offsite_backup::_name "$entry")
  if offsite_backup::_repository_reachable "$entry"; then
    logging::debug "offsite_backup: repository $name already initialized"
    context::set "offsite_backup.repositories.$name.ready" true
    return 0
  fi
  if ! offsite_backup::_init_consented "$(offsite_backup::_repository "$entry")"; then
    logging::warn "offsite_backup: repository $name does not exist and creating it was not consented — its scheduled runs will fail until it does. Re-apply with MACHINEKIT_OFFSITE_BACKUP_INIT_REPOSITORY=1, or run restic init yourself."
    context::set "offsite_backup.repositories.$name.ready" false
    return 0
  fi
  offsite_backup::_initialize_repository "$entry"
  context::set "offsite_backup.repositories.$name.ready" true
  logging::success "offsite_backup: created the restic repository $name."
}

# One consent signal covers every declared repository: the operator is authorizing
# "create the destinations this blueprint declares", and the blueprint already
# says exactly which those are. The prompt names the first one that is missing so
# an interactive yes is not answered blind.
offsite_backup::_init_consented() {
  local repository="$1" consent
  consent=$(context::get "offsite_backup.init_repository" --default false --coerce boolean \
    --prompt "Create any declared restic repository that does not exist yet, starting with $repository? (y/n)")
  [ "$consent" = "true" ]
}

# Whether a repository exists and opens with its installed password. Both this and
# the creation go through the installed run script rather than invoking restic
# here, so the repository, its password, and the backend credentials are assembled
# in exactly one place — the same place the scheduled runs use.
offsite_backup::_repository_reachable() {
  offsite_backup::_run_script_mode probe "$1"
}

offsite_backup::_initialize_repository() {
  offsite_backup::_run_script_mode init "$1"
}

# Run the installed script in MODE against one repository, with the same
# environment that repository's service units are given.
offsite_backup::_run_script_mode() {
  local mode="$1" entry="$2"
  local -a repository_env
  mapfile -t repository_env < <(offsite_backup::_common_service_env "$entry")
  env "MK_OFFSITE_BACKUP_MODE=$mode" "${repository_env[@]}" "$(offsite_backup::_run_script_path)"
}

# The environment both of a repository's services need: where it is, how to open
# it, which binary to drive, and where to report trouble. Secret file PATHS, never
# their values — a launchd plist is readable at rest, so the run script reads them
# itself at run time.
offsite_backup::_common_service_env() {
  local entry="$1" name
  name=$(offsite_backup::_name "$entry")
  printf '%s\n' \
    "MK_OFFSITE_BACKUP_NOTIFY=$(offsite_backup::_notify "$entry")" \
    "MK_OFFSITE_BACKUP_RESTIC=$(offsite_backup::_restic_path)" \
    "MK_OFFSITE_BACKUP_REPOSITORY=$(offsite_backup::_repository "$entry")" \
    "MK_OFFSITE_BACKUP_PASSWORD_FILE=$(offsite_backup::_password_file_path "$name")" \
    "MK_OFFSITE_BACKUP_CREDENTIALS_FILE=$(offsite_backup::_credentials_file_path "$name")"
}

offsite_backup::_install_backup_service() {
  local entry="$1" name
  name=$(offsite_backup::_name "$entry")
  local -a repository_env
  mapfile -t repository_env < <(offsite_backup::_common_service_env "$entry")
  service::install_calendar \
    "$(offsite_backup::_service_label "$name")" \
    "$(offsite_backup::_run_script_path)" \
    "$(offsite_backup::_schedule "$entry")" \
    "MK_OFFSITE_BACKUP_MODE=backup" \
    "${repository_env[@]}" \
    "MK_OFFSITE_BACKUP_MANIFEST=$(offsite_backup::_manifest_path "$name")" \
    "MK_OFFSITE_BACKUP_KEEP_DAILY=$(offsite_backup::_keep_daily "$entry")" \
    "MK_OFFSITE_BACKUP_KEEP_WEEKLY=$(offsite_backup::_keep_weekly "$entry")" \
    "MK_OFFSITE_BACKUP_KEEP_MONTHLY=$(offsite_backup::_keep_monthly "$entry")"
}

# The same script on a rarer cadence: verification re-reads the repository, which
# is the expensive part, so it does not ride every backup run.
offsite_backup::_install_check_service() {
  local entry="$1" name
  name=$(offsite_backup::_name "$entry")
  local -a repository_env
  mapfile -t repository_env < <(offsite_backup::_common_service_env "$entry")
  service::install_calendar \
    "$(offsite_backup::_service_label "$name")-check" \
    "$(offsite_backup::_run_script_path)" \
    "$(offsite_backup::_check_schedule "$entry")" \
    "MK_OFFSITE_BACKUP_MODE=check" \
    "${repository_env[@]}" \
    "MK_OFFSITE_BACKUP_READ_DATA=$(offsite_backup::_check_read_data "$entry")"
}

# --- config: the repository set and each entry's own fields ---

# Array-of-tables; `|| true` so an unset key is an empty result (no repositories
# is a valid no-op config), not a set -e failure.
offsite_backup::_repositories() {
  config::get "module.offsite_backup.repositories" || true
}

offsite_backup::_name() {
  printf '%s' "$1" | jq -r '.name'
}

offsite_backup::_repository() {
  printf '%s' "$1" | jq -r '.repository'
}

offsite_backup::_paths() {
  printf '%s' "$1" | jq -c '.paths // []'
}

# --- config: settings, each cascading repository over module default ---

# A repository's value for KEY, falling back to MODULE_DEFAULT. The single home of
# the entry-beats-module precedence; each setting below resolves its own module
# default (with its own coercion) and hands it here, so the cascade lives in one
# place and the per-key defaults stay with their keys.
offsite_backup::_repository_setting() {
  local entry="$1" key="$2" module_default="$3"
  printf '%s' "$entry" | jq -r --arg key "$key" --arg fallback "$module_default" '.[$key] // $fallback'
}

offsite_backup::_schedule() {
  offsite_backup::_repository_setting "$1" schedule \
    "$(config::get "module.offsite_backup.schedule" --default "$_OFFSITE_BACKUP_DEFAULT_SCHEDULE")"
}

offsite_backup::_check_schedule() {
  offsite_backup::_repository_setting "$1" check_schedule \
    "$(config::get "module.offsite_backup.check_schedule" --default "$_OFFSITE_BACKUP_DEFAULT_CHECK_SCHEDULE")"
}

offsite_backup::_keep_daily() {
  offsite_backup::_repository_setting "$1" keep_daily \
    "$(config::get "module.offsite_backup.keep_daily" --default "$_OFFSITE_BACKUP_DEFAULT_KEEP_DAILY")"
}

offsite_backup::_keep_weekly() {
  offsite_backup::_repository_setting "$1" keep_weekly \
    "$(config::get "module.offsite_backup.keep_weekly" --default "$_OFFSITE_BACKUP_DEFAULT_KEEP_WEEKLY")"
}

offsite_backup::_keep_monthly() {
  offsite_backup::_repository_setting "$1" keep_monthly \
    "$(config::get "module.offsite_backup.keep_monthly" --default "$_OFFSITE_BACKUP_DEFAULT_KEEP_MONTHLY")"
}

# Off by default: --read-data re-downloads every pack, so it is both slow and the
# one operation with real egress cost on a paid-egress backend.
offsite_backup::_check_read_data() {
  offsite_backup::_repository_setting "$1" check_read_data \
    "$(config::get "module.offsite_backup.check_read_data" --default false --coerce boolean)"
}

# Optional notify command; empty lets the run script fall back to logger/journald.
offsite_backup::_notify() {
  offsite_backup::_repository_setting "$1" notify \
    "$(config::get "module.offsite_backup.notify" --default "")"
}

# Whether install found or created this repository. Recorded by _ensure_repository
# so postflight reports the gap without probing the remote a second time.
offsite_backup::_repository_ready() {
  context::get "offsite_backup.repositories.$1.ready" --default false
}

# --- names + paths ---

# The bare logical name of one of a repository's secrets — the single source of
# it; every other function asks secrets::resolve/present for the rest.
offsite_backup::_secret_name() {
  printf '%s/%s/%s\n' "$_OFFSITE_BACKUP_SECRET_NAMESPACE" "$1" "$2"
}

# The bare service label for a repository's jobs (service.sh namespaces it per
# OS). The repository name is snake_case config, but a launchd label and a systemd
# unit read as one dash-separated word, so the underscores are translated here
# rather than forcing the config to a different casing.
offsite_backup::_service_label() {
  printf 'offsite-backup-%s\n' "${1//_/-}"
}

# The restic binary the service units pin. This module installs it, so apply's
# PATH (brew-prepended) resolves it; the detached daemon's minimal PATH would not,
# hence pinning the absolute path.
offsite_backup::_restic_path() {
  command -v restic
}

offsite_backup::_password_file_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/machinekit/offsite_backup/$1/repository_password"
}

offsite_backup::_credentials_file_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/machinekit/offsite_backup/$1/credentials"
}

offsite_backup::_manifest_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/offsite_backup/manifest-$1.tsv"
}

offsite_backup::_run_script_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/offsite_backup/restic_run.sh"
}
