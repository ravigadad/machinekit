#!/usr/bin/env bash
# postgres — capability module for a PostgreSQL instance. The consumer-facing API
# (ensure_database / ensure_role / ensure_extension / ensure_superuser,
# connection_string, version) is satisfier-independent — pure SQL and libpq
# strings — and runs through whichever satisfier is active: postgres_brew installs
# and runs postgres itself; postgres_app provisions into an operator-run
# Postgres.app. Consumers name the capability, never a satisfier.
#
# Four things vary by satisfier and are dispatched to the active one:
#   bin_dir                    — where psql/createuser for the resolved instance live
#   instance                   — the major serving 5432 (the instance consumers use)
#   ensure_extension_available — make an extension's binary installable/present
#   configure_container_access — engine-specific host reachability from containers
# Default satisfier is postgres_brew on every OS; a blueprint opts into postgres_app
# by listing it in modules = [...], resolved like container_manager/orbstack.

postgres::is_capability() { return 0; }

postgres::default_satisfier() { printf 'postgres_brew\n'; }

postgres::requires() { postgres::default_satisfier; }

postgres::install() { :; }

# After the container runtime is up, open postgres to containers: ensure the
# shared machinekit network exists — a consumer's compose attaches to it, and it
# is required on every OS even where the engine itself is reached over loopback —
# then let the active satisfier apply any engine-specific reachability (brew opens
# listen_addresses + pg_hba on Linux; Postgres.app needs nothing). Guarded on a
# container runtime being active: postgres integrates with one when present but
# does not require it, so with no runtime there is nothing to open. post_apply,
# not install: it needs the runtime up, and the network is what hindsight_server's
# later post_apply compose-up attaches to (dependency order guarantees this runs
# first).
postgres::post_apply() {
  modules::capability_active container_manager || return 0
  container_manager::ensure_network
  postgres::_dispatch configure_container_access
}

# The major version of the resolved instance (the server on 5432). Public reader
# for consumers that branch on the engine version — e.g. checking the major
# against what an extension supports.
postgres::version() {
  postgres::_dispatch instance_major_version
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
  local name="$1" password="$2" escaped_name escaped_password statement
  if input::is_dry_run; then
    logging::dry_run "would ensure role $name exists with the given password"
    return 0
  fi
  # Escape for SQL — double single-quotes in the literal password (the SQL-standard
  # escape, safe under standard_conforming_strings, on by default) and double-quotes
  # in the identifier — so a quote in either can't break out of the statement. The
  # statement is fed to psql on stdin, not an argv `-c`, so the password never lands
  # in the process arguments.
  escaped_name="${name//\"/\"\"}"
  escaped_password="${password//\'/\'\'}"
  if postgres::_role_exists "$name"; then
    statement="ALTER ROLE \"$escaped_name\" WITH LOGIN PASSWORD '$escaped_password'"
    printf '%s\n' "$statement" | postgres::_psql_exec_stdin postgres
    logging::debug "postgres: updated role $name password"
  else
    statement="CREATE ROLE \"$escaped_name\" WITH LOGIN PASSWORD '$escaped_password'"
    printf '%s\n' "$statement" | postgres::_psql_exec_stdin postgres
    logging::success "postgres: created role $name."
  fi
}

# Ensures the predictable `postgres` superuser exists so admin ops have a stable
# identity to act as. brew names the bootstrap superuser after the installing OS
# user (which scripts can't hardcode); Postgres.app already ships a `postgres`
# superuser. createuser connects as the bootstrap superuser and errors if the role
# is already present, which is our idempotency. Satisfiers call this from install,
# after their server is up.
postgres::ensure_superuser() {
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

# Makes EXT's binary available to the resolved instance, via the active satisfier
# (brew installs the extension's formula; Postgres.app bundles it, so a no-op).
# Distinct from ensure_extension, which runs CREATE EXTENSION inside a database:
# this readies the extension so that CREATE EXTENSION can succeed.
postgres::ensure_extension_available() {
  postgres::_dispatch ensure_extension_available "$1"
}

# Pure shape check on a requested {version, port} set; echoes the first problem
# found (empty = valid). Satisfier-independent — the table means the same for both
# — so it lives here and both satisfiers validate through it. Ports are compared
# as strings so quoted or bare TOML both work.
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

# The operator's requested {version, port} set, or nonzero when none is
# configured. Keyed on the capability's own config namespace, so both satisfiers
# read the same table: brew makes it true, postgres_app checks it.
postgres::_requested_versions() {
  config::get "module.postgres.versions"
}

# Fail with a clear message if the requested set is malformed. The pure check and
# the assert-and-fail around it are both satisfier-independent, so both satisfiers
# gate on this one function rather than repeating the wrapper (and its message
# prefix) each.
postgres::_assert_valid_request() {
  local err
  err="$(postgres::_request_shape_error "$1")"
  [ -z "$err" ] || lifecycle::fail "postgres: $err"
}

# Decode the requested {version, port} table into version⇥port rows (TSV), the one
# shape both satisfiers iterate — brew to install each, postgres_app to check each.
# Centralized so the table's encoding lives in one place, alongside its validation.
postgres::_requested_version_rows() {
  printf '%s' "$1" | jq -r '.[] | "\(.version)\t\(.port)"'
}

# The active satisfier module for the postgres capability. Every dispatch resolves
# through here, so no consumer-facing function names a concrete satisfier.
postgres::_satisfier() {
  modules::capability_satisfier postgres
}

# Dispatch a capability seam to the active satisfier, forwarding any args. The seams
# that genuinely vary by satisfier — instance_major_version, bin_dir,
# ensure_extension_available, configure_container_access — resolve the satisfier and
# call it identically, so they share this one indirection rather than repeating the
# resolve-and-call block.
postgres::_dispatch() {
  local seam="$1"; shift
  local satisfier
  satisfier="$(postgres::_satisfier)"
  "${satisfier}::${seam}" "$@"
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

# Like _psql_exec but reads the statement from stdin instead of an argv `-c`, so a
# secret embedded in the SQL (a role password) never appears in the process
# arguments — where `ps`/`/proc` would expose it. Used for the password-bearing
# role statements; the no-secret DDL and the SELECT checks stay on `-c`.
postgres::_psql_exec_stdin() {
  local db="$1"
  "$(postgres::_psql_path)" -X -q -U postgres -d "$db"
}

postgres::_psql_path() {
  printf '%s/psql\n' "$(postgres::_bin_dir)"
}

postgres::_createuser_path() {
  printf '%s/createuser\n' "$(postgres::_bin_dir)"
}

# The bin directory of the resolved instance, from the active satisfier — brew's
# keg-only bin, Postgres.app's Versions/<major>/bin.
postgres::_bin_dir() {
  postgres::_dispatch bin_dir
}

# --- ownership primitives (shared by satisfiers) ---

# True when something is listening on PORT. A bash /dev/tcp probe — a shell
# builtin, so no external tool (lsof/ss) and portable across macOS and Linux. Used
# only to detect that a port is occupied; which server owns it is answered from the
# data dir's postmaster.pid, not from the process table.
postgres::_port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# The port a running cluster is serving, read from DATADIR/postmaster.pid — the
# file a live cluster writes, whose 1st line is the postmaster PID and 4th line the
# port (a stable postgres contract). Nonzero when the cluster isn't running, so a
# caller can tell "not running" from "running on some port". A crash leaves a stale
# pidfile behind (postgres only removes it on a clean shutdown), so a bare
# file-exists test would trust a dead cluster and let the ownership guards match it
# while a foreign server actually holds the port; we confirm the PID is alive with
# kill -0 (a signal probe, not port-to-process inspection — no lsof/ps). An empty,
# dead, or non-numeric PID fails, as does one owned by another user, so the check
# fails closed. The data dir is a user-owned file, so no auth is needed.
postgres::_datadir_port() {
  local pidfile="$1/postmaster.pid" pid
  [ -f "$pidfile" ] || return 1
  pid="$(sed -n '1p' "$pidfile")"
  kill -0 "$pid" 2>/dev/null || return 1
  sed -n '4p' "$pidfile"
}
