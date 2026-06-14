#!/usr/bin/env bash
# postgres — manages the host's PostgreSQL instance(s) and offers idempotent
# provisioning primitives (ensure_database, ensure_extension, ensure_role) for
# consumer modules. Consumers never pick a version: "the instance" is whichever
# major's initialized cluster is on port 5432.
#
# By default the module ensures a single latest-major instance on 5432. An
# operator can instead pin a set of {version, port} pairs (one must be 5432);
# the module installs whichever are missing and verifies the rest. It never
# changes the port of an already-installed cluster and never initdb's (brew does
# that on install), so a request must account for every installed version.
#
# The module knows nothing about its consumers; extension formulae (e.g.
# pgvector) are installed by whichever module needs them. Admin ops act as the
# predictable `postgres` superuser (created on install — brew names the bootstrap
# superuser after the OS user). Read-only introspection lives in introspect.sh;
# container connectivity in access.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgres/introspect.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgres/access.sh"

postgres::install() {
  logging::step "postgres install"
  local requested
  if requested="$(postgres::_requested_versions)"; then
    postgres::_install_requested "$requested"
  else
    postgres::_install_default
  fi
  postgres::_ensure_superuser
}

# Opens the instance to containers when a container runtime is active; see
# access.sh. post_apply, not install: it needs the runtime present.
postgres::post_apply() {
  postgres::access::configure
}

# The major version of the resolved instance (the cluster on 5432). Public
# reader for consumers that branch on the engine version — e.g. checking the
# major against what an extension supports.
postgres::version() {
  postgres::introspect::instance_version
}

# A libpq URL for the resolved instance (always port 5432). No password: the
# caller composes it from its own secret, as a service does from its env file.
# The flavor selects the host — `host-local` for a process on this host,
# `container` for a container reaching the host via container_manager's alias.
postgres::connection_string() {
  local db="$1" user="$2" flavor="$3" host
  case "$flavor" in
    host-local) host="localhost" ;;
    container)  host="$(container_manager::host_alias)" ;;
    *) lifecycle::fail "postgres::connection_string: unknown flavor '$flavor' (expected host-local or container)" ;;
  esac
  printf 'postgresql://%s@%s:5432/%s\n' "$user" "$host" "$db"
}

# Ensures the database exists, optionally owned by an existing role. Ownership is
# re-asserted every run, not just on create: the owner is often a login role
# provisioned after the db (which is created under the postgres superuser), and a
# role can only run migration DDL against a db it owns. ALTER … OWNER TO is
# idempotent, so re-runs converge.
postgres::ensure_database() {
  local name="$1" owner="${2:-}"
  if input::is_dry_run; then
    logging::dry_run "would ensure database $name exists${owner:+ owned by $owner}"
    return 0
  fi
  if postgres::_db_exists "$name"; then
    logging::debug "postgres: database $name already exists"
  else
    postgres::_psql_exec postgres -c "CREATE DATABASE \"$name\""
    logging::success "postgres: created database $name."
  fi
  if [ -n "$owner" ]; then
    postgres::_psql_exec postgres -c "ALTER DATABASE \"$name\" OWNER TO \"$owner\""
  fi
}

postgres::ensure_extension() {
  local db="$1" ext="$2"
  if input::is_dry_run; then
    logging::dry_run "would ensure extension $ext in database $db"
    return 0
  fi
  postgres::_psql_exec "$db" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\""
}

# Ensures a LOGIN role exists with the given password. Converges rather than
# skipping: an existing role's password is updated to match, so a password
# argument is never silently ignored.
postgres::ensure_role() {
  local name="$1" password="$2"
  if input::is_dry_run; then
    logging::dry_run "would ensure role $name exists with the given password"
    return 0
  fi
  if postgres::_role_exists "$name"; then
    postgres::_psql_exec postgres -c "ALTER ROLE \"$name\" WITH LOGIN PASSWORD '$password'"
    logging::debug "postgres: updated role $name password"
  else
    postgres::_psql_exec postgres -c "CREATE ROLE \"$name\" WITH LOGIN PASSWORD '$password'"
    logging::success "postgres: created role $name."
  fi
}

postgres::_install_requested() {
  local requested="$1" err
  err="$(postgres::_request_shape_error "$requested")"
  [ -z "$err" ] || lifecycle::fail "postgres: $err"
  postgres::_assert_compatible_with_installed "$requested"
  postgres::_ensure_requested "$requested"
}

# Default (no `versions` configured): manage the single port-5432 instance. We
# never initdb (brew always does on install), so an installed-but-uninitialized
# formula, or a cluster the user parked on another port, is a hand-rolled setup
# we refuse to touch.
postgres::_install_default() {
  local version target
  if version="$(postgres::introspect::instance_version)"; then
    postgres::_ensure_running "$version"
    return 0
  fi
  target="$(postgres::introspect::latest_available_version)"
  if postgres::introspect::is_installed "$target"; then
    if postgres::introspect::is_initialized "$target"; then
      lifecycle::fail "postgres: postgresql@$target already has a cluster on a non-5432 port. Free port 5432 or remove that cluster, then re-run."
    fi
    lifecycle::fail "postgres: postgresql@$target is installed but its cluster was never initialized. machinekit does not initialize hand-rolled installs."
  fi
  postgres::_install_on_port "$target" 5432
}

# Pure shape check on the requested set; echoes the first problem found (empty =
# valid). Ports are compared as strings so quoted or bare TOML both work.
postgres::_request_shape_error() {
  printf '%s' "$1" | jq -r '
    if   any(.[]; (has("version")|not) or (has("port")|not)) then
      "each version entry must set both a version and a port"
    elif ([.[].version | tostring] | length != (unique | length)) then
      "a version appears more than once in the request"
    elif ([.[].port | tostring] | length != (unique | length)) then
      "a port appears more than once in the request"
    elif (any(.[]; (.port|tostring) == "5432") | not) then
      "no requested version is pinned to port 5432"
    else empty end'
}

# Reconcile the request with what's installed. We never remove or repoint an
# existing cluster, so each installed major must appear in the request, be
# initialized, and keep its current port.
postgres::_assert_compatible_with_installed() {
  local requested="$1" v requested_port actual_port
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    requested_port="$(printf '%s' "$requested" | jq -r --arg v "$v" \
      '.[] | select((.version|tostring) == $v) | (.port|tostring)')"
    [ -n "$requested_port" ] || lifecycle::fail \
      "postgres: postgresql@$v is installed but not in the requested versions; add it to the request (machinekit will not remove it)."
    postgres::introspect::is_initialized "$v" || lifecycle::fail \
      "postgres: postgresql@$v is installed but its cluster was never initialized. machinekit does not initialize hand-rolled installs."
    actual_port="$(postgres::introspect::configured_port "$v")"
    [ "$requested_port" = "$actual_port" ] || lifecycle::fail \
      "postgres: postgresql@$v is on port $actual_port; machinekit will not change an installed cluster's port to the requested $requested_port."
  done < <(postgres::introspect::installed_versions)
}

postgres::_ensure_requested() {
  local requested="$1" v port
  while IFS=$'\t' read -r v port; do
    [ -n "$v" ] || continue
    if postgres::introspect::is_installed "$v"; then
      postgres::_ensure_running "$v"
    else
      postgres::_install_on_port "$v" "$port"
    fi
  done < <(printf '%s' "$requested" | jq -r '.[] | "\(.version)\t\(.port)"')
}

# A freshly brew-installed cluster defaults to 5432 (commented). For any other
# port we set it before the first start, so two majors never collide on 5432.
postgres::_install_on_port() {
  local version="$1" port="$2"
  brew::install_formula "$(postgres::introspect::formula "$version")"
  [ "$port" = "5432" ] || postgres::_set_port "$version" "$port"
  postgres::_start "$version"
}

# Only ever called on a cluster machinekit just installed, never on a pre-
# existing one. Strips any active port line and appends ours, so it's idempotent
# and the commented brew default is left in place.
postgres::_set_port() {
  local version="$1" port="$2" conf tmp
  if input::is_dry_run; then
    logging::dry_run "would set postgresql@$version to port $port"
    return 0
  fi
  conf="$(postgres::introspect::data_dir "$version")/postgresql.conf"
  tmp="$(mktemp "${conf}.XXXXXX")"
  { grep -vE '^[[:space:]]*port[[:space:]]*=' "$conf" || true; printf 'port = %s\n' "$port"; } > "$tmp"
  mv "$tmp" "$conf"
}

postgres::_ensure_running() {
  local version="$1"
  if postgres::introspect::is_running "$version"; then
    logging::debug "postgres: postgresql@$version already running"
    return 0
  fi
  postgres::_start "$version"
}

# Headless-safe service start is OS-specific; brew::start_service owns that. The
# dry-run gate stays here because _start is also on the plain install path.
postgres::_start() {
  local version="$1"
  if input::is_dry_run; then
    logging::dry_run "would start postgresql@$version"
    return 0
  fi
  brew::start_service "$(postgres::introspect::formula "$version")"
}

# A full restart, not a reload: listen_addresses only takes effect on restart (a
# reload won't repoint the listener); a pg_hba change would reload, but the
# restart covers both.
postgres::_restart() {
  brew::restart_service "$(postgres::introspect::formula "$1")"
}

# brew names the bootstrap superuser after the installing OS user (ravi/admin),
# which scripts can't hardcode; create a predictable `postgres` superuser to act
# as. createuser connects as that bootstrap superuser (postgres may not exist
# yet) and errors if the role is already present, which is our idempotency.
postgres::_ensure_superuser() {
  if input::is_dry_run; then
    logging::dry_run "would ensure the postgres superuser exists"
    return 0
  fi
  if "$(postgres::_createuser_path)" -s postgres 2>/dev/null; then
    logging::success "postgres: created superuser postgres."
  else
    logging::debug "postgres: superuser postgres already present"
  fi
}

postgres::_createuser_path() {
  printf '%s/createuser\n' "$(postgres::introspect::bin_dir "$(postgres::introspect::instance_version)")"
}

postgres::_requested_versions() {
  config::get "module.postgres.versions"
}

postgres::_db_exists() {
  [ "$(postgres::_psql_exec postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$1'")" = "1" ]
}

postgres::_role_exists() {
  [ "$(postgres::_psql_exec postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$1'")" = "1" ]
}

# -X skips any user psqlrc; -q keeps command tags off stdout so callers only see
# query output; -U postgres is the predictable superuser identity (see above).
postgres::_psql_exec() {
  local db="$1"
  shift
  "$(postgres::_psql_path)" -X -q -U postgres -d "$db" "$@"
}

postgres::_psql_path() {
  printf '%s/psql\n' "$(postgres::introspect::bin_dir "$(postgres::introspect::instance_version)")"
}
