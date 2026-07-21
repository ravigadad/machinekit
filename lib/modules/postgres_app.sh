#!/usr/bin/env bash
# postgres_app — Postgres.app satisfier for the postgres capability (macOS only).
# Postgres.app is an operator-managed GUI server, so machinekit never installs,
# starts, or stops it: this satisfier CHECKS that reality matches the requested
# {version, port} set (where postgres_brew MAKES it true) and provisions the
# capability's databases/roles into the running server. If the operator asked for
# Postgres.app but a non-Postgres.app postgres holds the port, that is a harmful
# misconfiguration — we fail rather than provision into the wrong server.
#
# A running server is identified from its data dir's postmaster.pid (a stable
# postgres contract), never from the process table. The capability's SQL/connection
# API lives in capabilities/postgres.sh; this file provides the Postgres.app seams
# (instance, bin_dir, ensure_extension_available) plus the check.

_POSTGRES_APP_DIR="/Applications/Postgres.app"

postgres_app::provides() { printf 'postgres\n'; }

# Verify (never create) that the requested servers are running, then ensure the
# predictable superuser. No install/start/stop: Postgres.app owns its lifecycle.
postgres_app::install() {
  logging::step "postgres install"
  postgres_app::_assert_app_installed
  local requested
  if requested="$(postgres::_requested_versions)"; then
    postgres_app::_check_requested "$requested"
  else
    postgres_app::_check_default
  fi
  postgres::ensure_superuser
}

# --- capability seams ---

# The major of the resolved instance: the Postgres.app server on 5432.
postgres_app::instance_major_version() {
  postgres_app::_running_major_on_port 5432
}

# The bin directory for the resolved instance's client tools, under Postgres.app's
# per-major version bundle. Fails with a clear message when no server resolves,
# rather than returning a Versions//bin path with a zero exit — the brew satisfier
# aborts on the same empty-instance state, so both satisfiers diverge cleanly. The
# instance is captured to a local (|| major="") so a nonzero from
# instance_major_version reaches the guard instead of aborting silently under set -e.
postgres_app::bin_dir() {
  local major
  major="$(postgres_app::instance_major_version)" || major=""
  [ -n "$major" ] || lifecycle::fail \
    "postgres_app: no running Postgres.app server on port 5432 to resolve its client tools — start it, then re-run."
  printf '%s/Contents/Versions/%s/bin\n' "$_POSTGRES_APP_DIR" "$major"
}

# Postgres.app bundles its extensions (pgvector included), so there is nothing to
# install — CREATE EXTENSION will find it. A no-op, unlike the brew satisfier which
# installs the extension's formula.
postgres_app::ensure_extension_available() {
  logging::debug "postgres_app: extension $1 ships with Postgres.app; nothing to install"
}

# --- the check (postgres_app verifies the versions table rather than making it) ---

postgres_app::_check_requested() {
  local requested="$1" v port
  postgres::_assert_valid_request "$requested"
  while IFS=$'\t' read -r v port; do
    [ -n "$v" ] || continue
    postgres_app::_assert_server_on "$port" "$v"
  done < <(postgres::_requested_version_rows "$requested")
}

postgres_app::_check_default() {
  postgres_app::_assert_server_on 5432
}

# Assert a Postgres.app server is running on PORT (and, when EXPECTED_MAJOR is
# given, that it is that major). Distinguishes the harmful case — the port is held
# by a non-Postgres.app postgres — from an unstarted server, so the operator gets
# the right instruction.
postgres_app::_assert_server_on() {
  local port="$1" expected_major="${2:-}" major
  if ! major="$(postgres_app::_running_major_on_port "$port")"; then
    if postgres::_port_in_use "$port"; then
      lifecycle::fail "postgres_app: port $port is in use, but not by a Postgres.app server. You selected the postgres_app satisfier — stop the other postgres, or select postgres_brew if that is your provider."
    fi
    lifecycle::fail "postgres_app: no Postgres.app server is running on port $port. Start it in Postgres.app, then re-run."
  fi
  [ -z "$expected_major" ] || [ "$major" = "$expected_major" ] || lifecycle::fail \
    "postgres_app: the Postgres.app server on port $port is major $major, not the requested $expected_major."
}

# The major of the Postgres.app server currently on PORT, from each candidate data
# dir's postmaster.pid; nonzero when none is. Postgres.app names its data dirs
# var-<major> under Application Support/Postgres. A stopped cluster has no
# postmaster.pid, so _datadir_port fails — skip it via its exit status rather than
# comparing its empty output, which would otherwise false-match an empty PORT.
postgres_app::_running_major_on_port() {
  local port="$1" datadir major running_port
  for datadir in "$(postgres_app::_data_root)"/var-*; do
    [ -d "$datadir" ] || continue
    running_port="$(postgres::_datadir_port "$datadir")" || continue
    major="${datadir##*/var-}"
    [ "$running_port" = "$port" ] && { printf '%s\n' "$major"; return 0; }
  done
  return 1
}

postgres_app::_assert_app_installed() {
  [ -d "$_POSTGRES_APP_DIR" ] || lifecycle::fail \
    "postgres_app: Postgres.app is not installed at $_POSTGRES_APP_DIR. Install it, or select the postgres_brew satisfier."
}

postgres_app::_data_root() {
  printf '%s/Library/Application Support/Postgres\n' "$HOME"
}
