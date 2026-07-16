#!/usr/bin/env bash
# hindsight banks — module-neutral plumbing for Hindsight's bank-config API (a
# sibling of hindsight/secrets.sh). The caller owns config reading, consent, and
# which banks to send; this only speaks to the API.

# hindsight::banks::validate_shape BANKS_JSON — fail unless BANKS_JSON is a table
# whose every entry is itself a table of config fields. Catches both blueprint
# typos: a scalar/array where the whole bank map should be (`additional_banks =
# "music"`), and a scalar under a single bank name. Checked before apply.
hindsight::banks::validate_shape() {
  local banks_json="$1" malformed
  malformed="$(printf '%s' "$banks_json" \
    | jq 'if type != "object" then true else any(.[]; type != "object") end')"
  [ "$malformed" = "true" ] && lifecycle::fail \
    "hindsight: bank config must be a table of per-bank config tables."
  return 0
}

# hindsight::banks::server_reachable URL — true when the API answers a health
# probe. Its point is the same-box race: a server co-located with this apply may
# not be up yet, so a false result means "skip, retry next apply", not "fail".
hindsight::banks::server_reachable() {
  local url="${1%/}"
  curl -fsS "$url/health" >/dev/null 2>&1
}

# hindsight::banks::configure URL TOKEN TENANT BANK CONFIG_JSON — upsert one
# bank's config. Reachability is the caller's precondition, so a failure here is
# a real error (auth, a bad field) and is fatal.
hindsight::banks::configure() {
  local url="$1" token="$2" tenant="$3" bank="$4" body="$5" endpoint
  endpoint="${url%/}/v1/$tenant/banks/$bank/config"
  hindsight::banks::_http_patch "$endpoint" "$token" "$body" \
    || lifecycle::fail "hindsight: failed to configure bank '$bank' at $endpoint."
}

# The one place the tenant API is mutated. PATCH merges the given subset of
# config fields; Hindsight auto-creates a missing bank, so there is no
# create-before-config step. -f makes any non-2xx a non-zero exit. The bearer is
# fed on stdin (curl -H @-), not argv, so the fleet write credential never
# appears in the process table (ps / /proc/<pid>/cmdline) to other local users.
#
# The endpoint shape (/v1/<tenant>/banks/<bank>/config), the PATCH merge
# semantics, and the "default" tenant segment are from the upstream API docs, not
# a live run.
hindsight::banks::_http_patch() {
  local endpoint="$1" token="$2" body="$3"
  printf 'Authorization: Bearer %s\n' "$token" \
    | curl -fsS -X PATCH \
      -H @- \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$endpoint" >/dev/null
}
