#!/usr/bin/env bash
# postgres_dump — periodically dumps named databases to files at a path. Named
# for what it does, not what it is for: it produces files. Whether that amounts
# to a *backup* is a property of what else is pointed at the directory — a sync
# mesh replicating it, an offsite copy uploading it — never of this module, which
# is why it isn't called postgres_backup. It knows nothing about what lives in
# the databases it dumps.
#
# One service runs for all databases; the dump script (postgres_dump/dump.sh)
# iterates a manifest this module writes. The script runs out-of-band with a
# minimal PATH, so the service unit pins the resolved instance's pg_dump and
# pg_restore by absolute path, along with the superuser and port — all read
# through the postgres capability, so postgres_brew and postgres_app both work
# with no branching here.
#
# The scheduled-service mechanics — launchd/systemd unit generation and load —
# live in lib/machinekit/service.sh; postgres_dump hands it the dump script, a
# cron schedule, and that pinned environment. A cron spec is the one knob because
# it already expresses both "daily at 3am" and "every 6 hours".

_POSTGRES_DUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_POSTGRES_DUMP_DEFAULT_SCHEDULE="0 3 * * *"
_POSTGRES_DUMP_DEFAULT_RETAIN_COUNT="7"
_POSTGRES_DUMP_SERVICE_LABEL="postgres-dump"

postgres_dump::requires() {
  printf 'postgres\n'
}

# Fail early on a misconfigured database set or an unusable schedule, rather than
# partway through install (or, worse, silently at 3am). No databases configured =
# nothing to validate.
postgres_dump::preflight() {
  local databases default_directory
  databases=${ postgres_dump::_databases; }
  [ -n "$databases" ] || return 0
  default_directory=${ postgres_dump::_directory; }
  postgres_dump::_validate_databases "$databases" "$default_directory" "${ postgres_dump::_retain_count; }"
  service::validate_cron "${ postgres_dump::_schedule; }"
}

# The names of every file install may put in this module's own dirs, whatever the
# config, so an apply with no record of past installs can find them.
postgres_dump::installed_file_patterns() {
  printf '%s\n' \
    $'data\tmanifest.tsv' \
    $'data\tdump.sh'
}

# What install puts on this machine for the current config, so an apply can remove
# it once the last database or the module is dropped. No databases = nothing.
postgres_dump::installed_artifacts() {
  local databases
  databases=${ postgres_dump::_databases; }
  [ -n "$databases" ] || return 0
  printf 'service\t%s\n' "$_POSTGRES_DUMP_SERVICE_LABEL"
  printf 'file\t%s\n' "$(postgres_dump::_manifest_path)" "$(postgres_dump::_dump_script_path)"
}

# Write the manifest, lay down the dump script, and schedule the one service that
# runs it. No databases = nothing to install.
postgres_dump::install() {
  logging::step "postgres_dump install"
  local databases
  databases=${ postgres_dump::_databases; }
  if [ -z "$databases" ]; then
    logging::debug "postgres_dump: no databases configured; nothing to dump"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install the postgres-dump service (manifest, dump script, schedule '${ postgres_dump::_schedule; }')"
    return 0
  fi
  postgres_dump::_write_manifest
  postgres_dump::_install_dump_script
  postgres_dump::_install_service
  logging::success "postgres_dump: dump service installed."
}

# postflight: what this machine dumps, where, and how often — informational only.
# The service runs on its own, so there is no next step to surface here (a failing
# dump surfaces later through the notify hook, not at apply time).
postgres_dump::postflight_info() {
  local databases database name directory default_directory schedule
  databases=${ postgres_dump::_databases; }
  [ -n "$databases" ] || return 0
  default_directory=${ postgres_dump::_directory; }
  schedule=${ postgres_dump::_schedule; }
  while IFS= read -u 3 -r database; do
    [ -n "$database" ] || continue
    name=$(printf '%s' "$database" | jq -r '.name')
    directory=$(printf '%s' "$database" \
      | jq -r --arg default "$default_directory" '.directory // $default')
    printf 'Dumping database %s to %s on schedule "%s".\n' "$name" "$directory" "$schedule"
  done 3< <(printf '%s' "$databases" | jq -c '.[]')
}

# Fail loudly on a malformed database set rather than writing a half-usable
# manifest. The defaults are passed in because every per-entry key may fall back
# to one, so only the *resolved* value is worth validating.
postgres_dump::_validate_databases() {
  local shape_error
  shape_error="$(postgres_dump::_database_shape_error "$@")"
  [ -z "$shape_error" ] || lifecycle::fail "postgres_dump: $shape_error"
}

# Pure shape check on the database set against the module-level defaults; echoes
# the first problem found (empty = valid). Kept separate from the assert so the
# rules are testable without a failing-exit collaborator in the way.
postgres_dump::_database_shape_error() {
  local databases="$1" default_directory="$2" default_retain_count="$3"
  printf '%s' "$databases" | jq -r \
    --arg directory "$default_directory" \
    --arg retain_count "$default_retain_count" '
    if   any(.[]; (.name // "") == "") then
      "every [module.postgres_dump.databases.<key>] entry needs a name (the name defaults to the key)"
    elif any(.[]; ((.directory // $directory) == "")) then
      "every database needs a directory: set [module.postgres_dump].directory, or one on the entry"
    elif any(.[]; ((.retain_count // $retain_count) | tostring | test("^[0-9]+$") | not)) then
      "retain_count must be a whole number"
    else empty end'
}

# Write the manifest the dump script iterates: one tab-separated row per database.
postgres_dump::_write_manifest() {
  local manifest databases default_directory default_retain_count database
  manifest=$(postgres_dump::_manifest_path)
  mkdir -p "$(dirname "$manifest")"
  : > "$manifest"
  databases=${ postgres_dump::_databases; }
  [ -n "$databases" ] || return 0
  default_directory=${ postgres_dump::_directory; }
  default_retain_count=${ postgres_dump::_retain_count; }
  while IFS= read -u 3 -r database; do
    [ -n "$database" ] || continue
    postgres_dump::_manifest_row "$database" "$default_directory" "$default_retain_count" >> "$manifest"
  done 3< <(printf '%s' "$databases" | jq -c '.[]')
}

# One manifest row (name<TAB>directory<TAB>retain_count) for a database, each
# field falling back to the module-level default.
postgres_dump::_manifest_row() {
  local database="$1" default_directory="$2" default_retain_count="$3"
  local name directory retain_count
  name=$(printf '%s' "$database" | jq -r '.name')
  directory=$(printf '%s' "$database" \
    | jq -r --arg default "$default_directory" '.directory // $default')
  directory=${directory/#\~/$HOME}
  retain_count=$(printf '%s' "$database" \
    | jq -r --arg default "$default_retain_count" '.retain_count // $default')
  printf '%s\t%s\t%s\n' "$name" "$directory" "$retain_count"
}

postgres_dump::_install_dump_script() {
  local dest
  dest=$(postgres_dump::_dump_script_path)
  mkdir -p "$(dirname "$dest")"
  cp "$_POSTGRES_DUMP_DIR/postgres_dump/dump.sh" "$dest"
  chmod 755 "$dest"
}

# Schedule the one service that runs the dump script for every database, pinning
# the manifest, notify command, client-tool paths, and connection identity into
# its environment. The dump script is a self-contained executable, so
# service::install_calendar runs it directly (its shebang picks the interpreter);
# the launchd/systemd split is service.sh's job.
postgres_dump::_install_service() {
  service::install_calendar \
    "$_POSTGRES_DUMP_SERVICE_LABEL" \
    "$(postgres_dump::_dump_script_path)" \
    "${ postgres_dump::_schedule; }" \
    "MK_POSTGRES_DUMP_MANIFEST=$(postgres_dump::_manifest_path)" \
    "MK_POSTGRES_DUMP_NOTIFY=${ postgres_dump::_notify; }" \
    "MK_POSTGRES_DUMP_PG_DUMP=${ postgres::pg_dump_path; }" \
    "MK_POSTGRES_DUMP_PG_RESTORE=${ postgres::pg_restore_path; }" \
    "MK_POSTGRES_DUMP_USER=$(postgres::superuser)" \
    "MK_POSTGRES_DUMP_PORT=$(postgres::port)"
}

# --- config accessors + paths ---

# Each entry's key is the database name unless it sets `name`, so
# `[module.postgres_dump.databases.hindsight]` alone dumps the hindsight database.
# Empty when none are configured (no databases is a valid no-op config).
postgres_dump::_databases() {
  config::entries "module.postgres_dump.databases" name
}

postgres_dump::_schedule() {
  config::get "module.postgres_dump.schedule" --default "$_POSTGRES_DUMP_DEFAULT_SCHEDULE"
}

# No default: the whole point of this module is that something else is pointed at
# the directory it writes to, so inventing a location would invite a silent
# mismatch. Preflight rejects a database with no directory to resolve.
postgres_dump::_directory() {
  config::get "module.postgres_dump.directory" --default ""
}

postgres_dump::_retain_count() {
  config::get "module.postgres_dump.retain_count" --default "$_POSTGRES_DUMP_DEFAULT_RETAIN_COUNT"
}

# Optional notify command; empty lets the dump script fall back to logger/journald.
postgres_dump::_notify() {
  config::get "module.postgres_dump.notify" --default ""
}

postgres_dump::_manifest_path() {
  printf '%s\n' "${ artifacts::module_data_dir postgres_dump; }/manifest.tsv"
}

postgres_dump::_dump_script_path() {
  printf '%s\n' "${ artifacts::module_data_dir postgres_dump; }/dump.sh"
}
