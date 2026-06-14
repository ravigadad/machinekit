#!/usr/bin/env bash
# postgres::introspect — read-only, version-keyed facts about postgres installs.
# brew gives you a formula (postgresql@<major>: one keg + one default cluster per
# major), not an instance; these answer every fact the provisioner and resolver
# need, keyed by major version. Versioned formulae are keg-only, so client
# binaries resolve through the keg prefix, not PATH. Nothing here mutates.

# Builds the versioned formula name. A bogus version (postgresql@foo, @21) isn't
# caught here — it surfaces loudly where brew is actually consulted (install, or
# bin_dir's `brew --prefix`), which fails cleanly under set -e rather than a
# lifecycle::fail swallowed inside a command substitution.
postgres::introspect::formula() {
  [ -n "${1:-}" ] || lifecycle::fail "postgres::introspect: a postgres major version is required"
  printf 'postgresql@%s\n' "$1"
}

postgres::introspect::installed_versions() {
  brew::_installed formula | sed -n 's/^postgresql@//p'
}

postgres::introspect::is_installed() {
  brew::_is_installed formula "$(postgres::introspect::formula "$1")"
}

postgres::introspect::latest_available_version() {
  brew info --json=v2 postgresql | jq -r '.formulae[0].name' | sed 's/^postgresql@//'
}

postgres::introspect::data_dir() {
  printf '%s/var/%s\n' "$(brew --prefix)" "$(postgres::introspect::formula "$1")"
}

postgres::introspect::bin_dir() {
  printf '%s/bin\n' "$(brew --prefix "$(postgres::introspect::formula "$1")")"
}

postgres::introspect::pg_ctl_path() {
  printf '%s/pg_ctl\n' "$(postgres::introspect::bin_dir "$1")"
}

postgres::introspect::is_initialized() {
  [ -f "$(postgres::introspect::data_dir "$1")/PG_VERSION" ]
}

# brew ships postgresql.conf with `port` commented, which means 5432; a missing
# file or no uncommented line means the same. Only an explicit line overrides.
postgres::introspect::configured_port() {
  local conf port=""
  conf="$(postgres::introspect::data_dir "$1")/postgresql.conf"
  if [ -f "$conf" ]; then
    port=$(sed -nE 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$conf" | tail -n1)
  fi
  printf '%s\n' "${port:-5432}"
}

postgres::introspect::is_running() {
  "$(postgres::introspect::pg_ctl_path "$1")" status -D "$(postgres::introspect::data_dir "$1")" >/dev/null 2>&1
}

# "The instance" is the major whose initialized cluster is on 5432. The
# is_initialized guard matters: configured_port defaults to 5432 for an
# uninitialized install, which would otherwise false-match. Nonzero = none yet.
postgres::introspect::instance_version() {
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if postgres::introspect::is_initialized "$v" && [ "$(postgres::introspect::configured_port "$v")" = "5432" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  done < <(postgres::introspect::installed_versions)
  return 1
}
