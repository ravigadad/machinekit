#!/usr/bin/env bash
# postgres_brew — brew satisfier for the postgres capability. Installs and runs
# PostgreSQL via Homebrew: it MAKES the requested {version, port} set true (where
# postgres_app only checks it). By default it ensures a single latest-major
# instance on 5432. An operator can instead pin a set of {version, port} pairs (one
# must be 5432); it installs whichever are missing and verifies the rest. It never
# changes the port of an already-installed cluster and never initdb's (brew does
# that on install), so a request must account for every installed version.
#
# The satisfier-independent SQL/connection API lives on the capability
# (capabilities/postgres.sh); this file provides the brew-specific seams (instance,
# bin_dir, ensure_extension_available) plus install and container access. Read-only
# brew introspection lives in introspect.sh; container connectivity in access.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgres_brew/introspect.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgres_brew/access.sh"

postgres_brew::provides() { printf 'postgres\n'; }

postgres_brew::install() {
  logging::step "postgres install"
  local requested
  if requested="$(postgres::_requested_versions)"; then
    postgres_brew::_install_requested "$requested"
  else
    postgres_brew::_install_default
  fi
  postgres::ensure_superuser
}

# Opens the instance to containers when a container runtime is active; see
# access.sh. post_apply, not install: it needs the runtime present.
postgres_brew::post_apply() {
  postgres_brew::access::configure
}

# --- capability seams ---

# The major of the resolved instance: the initialized cluster on 5432.
postgres_brew::instance_major_version() {
  postgres_brew::introspect::instance_version
}

# The bin directory for the resolved instance's client tools. Versioned formulae
# are keg-only, so this resolves through the keg prefix, not PATH.
postgres_brew::bin_dir() {
  postgres_brew::introspect::bin_dir "$(postgres_brew::introspect::instance_version)"
}

# Makes an extension available by installing its brew formula. Extensions ship as
# their own formulae (the `vector` extension is the `pgvector` formula), so map the
# extension name to its formula and install it.
postgres_brew::ensure_extension_available() {
  brew::install_formula "$(postgres_brew::_extension_formula "$1")"
}

postgres_brew::_extension_formula() {
  case "$1" in
    vector) printf 'pgvector\n' ;;
    *) lifecycle::fail "postgres_brew: no known brew formula for extension '$1'" ;;
  esac
}

# --- install orchestration (brew makes the versions table true) ---

postgres_brew::_install_requested() {
  local requested="$1"
  postgres::_assert_valid_request "$requested"
  postgres_brew::_assert_compatible_with_installed "$requested"
  postgres_brew::_ensure_requested "$requested"
}

# Default (no `versions` configured): manage the single port-5432 instance. We
# never initdb (brew always does on install), so an installed-but-uninitialized
# formula, or a cluster the user parked on another port, is a hand-rolled setup
# we refuse to touch.
postgres_brew::_install_default() {
  local version target
  if version="$(postgres_brew::introspect::instance_version)"; then
    postgres_brew::_ensure_running "$version"
    return 0
  fi
  target="$(postgres_brew::introspect::latest_available_version)"
  if postgres_brew::introspect::is_installed "$target"; then
    if postgres_brew::introspect::is_initialized "$target"; then
      lifecycle::fail "postgres: postgresql@$target already has a cluster on a non-5432 port. Free port 5432 or remove that cluster, then re-run."
    fi
    lifecycle::fail "postgres: postgresql@$target is installed but its cluster was never initialized. machinekit does not initialize hand-rolled installs."
  fi
  postgres_brew::_install_on_port "$target" 5432
}

# Reconcile the request with what's installed. We never remove or repoint an
# existing cluster, so each installed major must appear in the request, be
# initialized, and keep its current port.
postgres_brew::_assert_compatible_with_installed() {
  local requested="$1" v requested_port actual_port
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    requested_port="$(printf '%s' "$requested" | jq -r --arg v "$v" \
      '.[] | select((.version|tostring) == $v) | (.port|tostring)')"
    [ -n "$requested_port" ] || lifecycle::fail \
      "postgres: postgresql@$v is installed but not in the requested versions; add it to the request (machinekit will not remove it)."
    postgres_brew::introspect::is_initialized "$v" || lifecycle::fail \
      "postgres: postgresql@$v is installed but its cluster was never initialized. machinekit does not initialize hand-rolled installs."
    actual_port="$(postgres_brew::introspect::configured_port "$v")"
    [ "$requested_port" = "$actual_port" ] || lifecycle::fail \
      "postgres: postgresql@$v is on port $actual_port; machinekit will not change an installed cluster's port to the requested $requested_port."
  done < <(postgres_brew::introspect::installed_versions)
}

postgres_brew::_ensure_requested() {
  local requested="$1" v port
  while IFS=$'\t' read -r v port; do
    [ -n "$v" ] || continue
    if postgres_brew::introspect::is_installed "$v"; then
      postgres_brew::_ensure_running "$v"
    else
      postgres_brew::_install_on_port "$v" "$port"
    fi
  done < <(postgres::_requested_version_rows "$requested")
}

# A freshly brew-installed cluster defaults to 5432 (commented). For any other
# port we set it before the first start, so two majors never collide on 5432.
postgres_brew::_install_on_port() {
  local version="$1" port="$2"
  postgres_brew::_assert_port_not_foreign "$port"
  brew::install_formula "$(postgres_brew::introspect::formula "$version")"
  [ "$port" = "5432" ] || postgres_brew::_set_port "$version" "$port"
  postgres_brew::_start "$version"
}

# Refuse to install onto a port already held by a postgres that isn't one of our
# own brew clusters: a second cluster there would collide at start, and silently
# provisioning against a foreign server (e.g. a Postgres.app the operator meant to
# select instead) is the harmful misconfiguration. A free port, or one already
# served by our own brew cluster, is fine.
postgres_brew::_assert_port_not_foreign() {
  local port="$1"
  postgres::_port_in_use "$port" || return 0
  postgres_brew::_port_is_my_cluster "$port" && return 0
  lifecycle::fail "postgres_brew: port $port is already in use by a non-brew postgres. Free it, or select the postgres_app satisfier if that is your provider, then re-run."
}

# True when one of our installed brew clusters is the server currently on PORT —
# its data dir's postmaster.pid reports that port.
postgres_brew::_port_is_my_cluster() {
  local port="$1" major
  while IFS= read -r major; do
    [ -n "$major" ] || continue
    [ "$(postgres::_datadir_port "$(postgres_brew::introspect::data_dir "$major")")" = "$port" ] && return 0
  done < <(postgres_brew::introspect::installed_versions)
  return 1
}

# Only ever called on a cluster machinekit just installed, never on a pre-
# existing one. Strips any active port line and appends ours, so it's idempotent
# and the commented brew default is left in place.
postgres_brew::_set_port() {
  local version="$1" port="$2" conf tmp
  if input::is_dry_run; then
    logging::dry_run "would set postgresql@$version to port $port"
    return 0
  fi
  conf="$(postgres_brew::introspect::data_dir "$version")/postgresql.conf"
  tmp="$(mktemp "${conf}.XXXXXX")"
  { grep -vE '^[[:space:]]*port[[:space:]]*=' "$conf" || true; printf 'port = %s\n' "$port"; } > "$tmp"
  mv "$tmp" "$conf"
}

postgres_brew::_ensure_running() {
  local version="$1"
  if postgres_brew::introspect::is_running "$version"; then
    logging::debug "postgres: postgresql@$version already running"
    return 0
  fi
  postgres_brew::_start "$version"
}

# Headless-safe service start is OS-specific; brew::start_service owns that. The
# dry-run gate stays here because _start is also on the plain install path.
postgres_brew::_start() {
  local version="$1"
  if input::is_dry_run; then
    logging::dry_run "would start postgresql@$version"
    return 0
  fi
  brew::start_service "$(postgres_brew::introspect::formula "$version")"
}

# A full restart, not a reload: listen_addresses only takes effect on restart (a
# reload won't repoint the listener); a pg_hba change would reload, but the
# restart covers both.
postgres_brew::_restart() {
  brew::restart_service "$(postgres_brew::introspect::formula "$1")"
}
