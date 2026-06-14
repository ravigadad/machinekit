#!/usr/bin/env bash
# postgres::access — makes the host instance reachable from containers, but only
# when a container runtime is active (a soft, optional dependency: postgres does
# NOT `require` container_manager — it integrates only if one happens to be in
# the active set). macOS/OrbStack containers reach the host over loopback, which
# brew's default pg_hba already trusts, so it's a no-op there. On Linux the
# container appears on a bridge subnet, so we open listen_addresses and add a
# scram-authenticated pg_hba line scoped to that subnet (scram is the real gate;
# the CIDR is defense-in-depth). Lives in post_apply, not install: it needs the
# container runtime present, and postgres/container_manager are siblings so
# install order isn't guaranteed.

postgres::access::configure() {
  modules::capability_active container_manager || return 0
  case "$(context::get os.family)" in
    darwin)
      logging::debug "postgres: containers reach the host over loopback; no access changes needed"
      ;;
    linux)
      postgres::access::_open_for_containers
      ;;
  esac
}

postgres::access::_open_for_containers() {
  if input::is_dry_run; then
    logging::dry_run "would open postgres to the container subnet (listen_addresses + pg_hba) and restart"
    return 0
  fi
  local version subnet
  version="$(postgres::introspect::instance_version)" || lifecycle::fail \
    "postgres: no running instance found to open for containers."
  subnet="$(container_manager::container_subnet)"
  postgres::access::_open_listen "$version"
  postgres::access::_authorize_subnet "$version" "$subnet"
  postgres::_restart "$version"
  logging::success "postgres: opened container access from $subnet."
}

postgres::access::_open_listen() {
  postgres::access::_write_block \
    "$(postgres::introspect::data_dir "$1")/postgresql.conf" \
    "listen_addresses = '*'"
}

postgres::access::_authorize_subnet() {
  local version="$1" subnet="$2"
  postgres::access::_write_block \
    "$(postgres::introspect::data_dir "$version")/pg_hba.conf" \
    "host all all $subnet scram-sha-256"
}

# Idempotent: strip machinekit's marked block if present, then append a fresh
# one. Never a blind append, so re-runs converge on a single block.
postgres::access::_write_block() {
  local file="$1" content="$2" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  sed '/^# >>> machinekit:postgres >>>$/,/^# <<< machinekit:postgres <<<$/d' "$file" > "$tmp"
  {
    printf '# >>> machinekit:postgres >>>\n'
    printf '%s\n' "$content"
    printf '# <<< machinekit:postgres <<<\n'
  } >> "$tmp"
  mv "$tmp" "$file"
}
