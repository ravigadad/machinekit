#!/usr/bin/env bash
# secrets — the blueprint secrets pool model: what it currently holds, what the
# active modules say they need, where a secret lands, and how it is written. The
# presentation (render), the put use-case, and the CLI actions live in secrets/.
[ -n "${_MK_SECRETS_LOADED:-}" ] && return 0
_MK_SECRETS_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets/render.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets/put.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets/cli.sh"

# Pool root, blueprint-relative. Every module namespaces its secrets under this
# (secrets/<service>/...); the single source of the prefix. Modules never hardcode
# it — they compose paths through secrets::pool_path.
_MK_SECRETS_POOL_REL="secrets"

# The reserved logical name of the user's age identity key. The age module sources
# it from a file or a secrets manager — never from the age pool, because the key
# can't decrypt itself (chicken-and-egg). backend_for enforces that invariant. The
# single source of the name, shared by the age module (which declares/resolves it)
# and secrets.sh (which guards it).
_MK_SECRETS_AGE_KEY_NAME="age_key"

# secrets::pool_path SUBPATH — the blueprint-relative path of SUBPATH inside the
# secrets pool. The single place the pool prefix lives: a secret-bearing module
# passes only its own namespace (e.g. "tailscale/home.age") and gets the full pool
# path back, so renaming the pool means editing _MK_SECRETS_POOL_REL alone.
secrets::pool_path() {
  printf '%s/%s\n' "$_MK_SECRETS_POOL_REL" "$1"
}

# secrets::resolve NAME — the plaintext value of the named secret on stdout,
# whichever backend actually holds it. The one primitive every pool-secret
# consumer calls instead of decrypting an age pool file directly — no caller
# needs to know age or a secrets manager is involved.
secrets::resolve() {
  local name="$1"
  case "$(secrets::backend_for "$name")" in
    manager) secrets_manager::fetch "$(secrets::_reference_for "$name")" ;;
    pool)    age::decrypt "$(secrets::_pool_file_path "$name")" ;;
    *)       return 1 ;;
  esac
}

# secrets::present NAME — true when some backend currently resolves NAME.
secrets::present() {
  [ "$(secrets::backend_for "$1")" != "none" ]
}

# secrets::_local_signal NAME — the local, no-network backend signal for NAME:
# "ref" when an explicit [secrets.manager_refs] reference is configured (which
# overrides even a pool file that also exists — it lets a secret be swapped to the
# manager without touching the pool), "pool" when an age-pool file exists, else
# empty (convention-backed or absent). The single source of the explicit-ref-beats-
# pool precedence, shared by backend_for (runtime resolution) and
# backend_requirements (the ::requires dependency edge) so the two can never
# disagree on which backend a name is bound to.
secrets::_local_signal() {
  local name="$1"
  if [ -n "$(secrets::_manager_ref "$name")" ]; then
    printf 'ref\n'
  elif [ -f "$(secrets::_pool_file_path "$name")" ]; then
    printf 'pool\n'
  fi
}

# secrets::backend_for NAME — which backend resolves NAME right now: "manager"
# (a secrets-manager satisfier is active and truly holds NAME), "pool" (an
# age-pool file exists), or "none". Presence is truthful, never optimistic: both
# manager verdicts are confirmed against what the satisfier readied in preflight,
# so a secret absent from every backend reports "none", never a false "manager"
# that would defeat provide-or-generate or mislead `secrets list`. An explicit ref
# whose manager does NOT hold it reports "none" (not "pool"): the ref is a
# directive to use the manager, so silently falling back to the overridden pool
# file would hide the miss.
secrets::backend_for() {
  local name="$1"
  case "$(secrets::_local_signal "$name")" in
    ref)
      if modules::capability_active secrets_manager \
        && secrets_manager::has_reference "$(secrets::_manager_ref "$name")"; then
        printf 'manager\n'
      else
        printf 'none\n'
      fi ;;
    pool)
      printf 'pool\n' ;;
    *)
      if modules::capability_active secrets_manager && secrets_manager::has "$name"; then
        printf 'manager\n'
      else
        printf 'none\n'
      fi ;;
  esac
}

# secrets::backend_requirements — read secret names on stdin (one per line) and
# emit the backend modules they require: "age" if any is backed by an age-pool
# file, "secrets_manager" if any names an explicit manager reference. The one
# home of the backend→dependency-module mapping, shared by every module's
# ::requires. Local signals only (via secrets::_local_signal): it runs during
# resolution, before the manager is readied, so it never probes the manager. A
# convention-backed name (no ref, no pool file) needs no edge — its satisfier is
# already listed in modules = [...], and readiness authenticates in preflight
# before any module installs.
secrets::backend_requirements() {
  local name needs_age=0 needs_manager=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$(secrets::_local_signal "$name")" in
      ref)  needs_manager=1 ;;
      pool) needs_age=1 ;;
    esac
  done
  [ "$needs_age" = 1 ] && printf 'age\n'
  [ "$needs_manager" = 1 ] && printf 'secrets_manager\n'
  return 0
}

# secrets::assert_age_key_not_pooled — enforce the invariant that the age key is
# never an age-pool secret (it can't decrypt itself). Fails loudly on a stray
# secrets/age_key.age. This lives outside backend_for and MUST be called from a
# main-shell context, because backend_for is always invoked inside a command
# substitution — a lifecycle::fail there would exit only the subshell and the run
# would march on. Called at each secret-inspecting entry point (preflight, secrets
# list, secrets put) after the blueprint is resolved.
secrets::assert_age_key_not_pooled() {
  [ -f "$(secrets::_pool_file_path "$_MK_SECRETS_AGE_KEY_NAME")" ] || return 0
  lifecycle::fail "secrets: found a pool file for '$_MK_SECRETS_AGE_KEY_NAME' — the age key can't live in the age pool (it would need itself to decrypt). Remove it; source the age key from a file or a secrets manager."
}

# secrets::declared_backend_requirements — read declared-secret rows (a module's
# declared_secrets output: `name<TAB>required<TAB>can_be_generated`) on stdin and
# emit the backend modules those secrets require. The single home of the "field 1
# is the secret name" coupling, shared by every secret-bearing module's ::requires
# so the row layout lives in one place, not re-decoded per module.
secrets::declared_backend_requirements() {
  cut -f1 | secrets::backend_requirements
}

# secrets::_pool_file_path NAME — the absolute age-pool file path for NAME.
secrets::_pool_file_path() {
  printf '%s/%s\n' "$(blueprints::dir)" "$(secrets::pool_path "$1.age")"
}

# secrets::_manager_ref NAME — the explicit manager reference configured for
# NAME ([secrets.manager_refs] "NAME" = "..."), or empty if none. Reads the whole
# table and extracts NAME as a literal jq key: config::get splits its dotted path
# on ".", so interpolating NAME into the path would silently miss a secret name
# that itself contains a dot.
secrets::_manager_ref() {
  local refs_json
  refs_json="$(config::get "secrets.manager_refs" 2>/dev/null || true)"
  [ -n "$refs_json" ] || return 0
  printf '%s' "$refs_json" | jq -r --arg name "$1" '.[$name] // empty'
}

# secrets::_reference_for NAME — the reference to hand a secrets-manager
# satisfier: the explicit configured one, or NAME itself when relying on the
# manager's own convention-derived lookup.
secrets::_reference_for() {
  local configured_ref
  configured_ref="$(secrets::_manager_ref "$1")"
  if [ -n "$configured_ref" ]; then
    printf '%s\n' "$configured_ref"
  else
    printf '%s\n' "$1"
  fi
}

# secrets::in_pool — the blueprint-relative path of every .age secret currently
# in the pool, one per line, sorted. Empty when the pool dir is absent.
secrets::in_pool() {
  local blueprint_dir pool_dir file
  blueprint_dir="$(blueprints::dir)"
  pool_dir="$blueprint_dir/$_MK_SECRETS_POOL_REL"
  [ -d "$pool_dir" ] || return 0
  while IFS= read -r file; do
    printf '%s\n' "${file#"$blueprint_dir"/}"
  done < <(find "$pool_dir" -type f -name '*.age' | sort)
}

# secrets::needed — every named secret the active modules declare they will use,
# as `name<TAB>required<TAB>can_be_generated` lines (the latter two booleans,
# "true"/"false"). The union across active modules' declared_secrets hooks, resolved
# against current context (a module emits only the secrets it will actually use on
# this machine).
secrets::needed() {
  modules::collect declared_secrets
}

# secrets::inventory — the secrets the active modules declare, joined with the
# backend that actually resolves each: `name<TAB>required<TAB>can_be_generated
# <TAB>state` rows, one per declared secret, sorted by name. required and
# can_be_generated are the booleans the module declared; state is `pool`,
# `manager`, or `missing` (secrets::backend_for's "none", renamed for the
# CLI-facing term). Pool secrets no module declares are not here — see
# secrets::orphans.
secrets::inventory() {
  local -A required=() can_be_generated=()
  local name req gen state

  while IFS=$'\t' read -r name req gen; do
    [ -n "$name" ] || continue
    required["$name"]="$req"
    can_be_generated["$name"]="$gen"
  done < <(secrets::needed)

  for name in "${!required[@]}"; do printf '%s\n' "$name"; done \
    | sort | while IFS= read -r name; do
    state=$(secrets::backend_for "$name")
    [ "$state" = "none" ] && state="missing"
    printf '%s\t%s\t%s\t%s\n' "$name" "${required[$name]}" "${can_be_generated[$name]}" "$state"
  done
}

# secrets::orphans — pool files no active module's declared name accounts for,
# one blueprint-relative .age path per line, sorted. Usually a typo or a stale
# entry; surfaced apart from the inventory so a stray pool file is flagged
# rather than presented as something a module needs.
secrets::orphans() {
  local -A declared=()
  local name path bare
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    declared["$name"]=1
  done < <(secrets::needed)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    bare="${path#"$_MK_SECRETS_POOL_REL"/}"
    bare="${bare%.age}"
    [ -n "${declared[$bare]:-}" ] || printf '%s\n' "$path"
  done < <(secrets::in_pool)
}

# secrets::blueprints_dir — the local blueprint working tree `secrets put` writes
# into, as an absolute path: the --blueprints-dir override, else blueprints.source
# when that is local (a plain path or file:// URL). Fails when only a remote source
# is known, since the write target must be a working tree you commit from — the
# apply-time fetch cache is throwaway and never written to.
secrets::blueprints_dir() {
  local override source dir
  override=$(context::get "secrets.blueprints_dir" || true)
  if [ -n "$override" ]; then
    dir="$override"
  else
    source=$(context::get "blueprints.source" || true)
    case "$source" in
      "") lifecycle::fail "secrets: no blueprint working tree — pass --blueprints-dir (your local clone)." ;;
      file://*) dir="${source#file://}" ;;
      http://*|https://*|ssh://*|git@*)
        lifecycle::fail "secrets: blueprints.source is remote ($source) — pass --blueprints-dir (your local clone) to place secrets into." ;;
      *) dir="$source" ;;
    esac
  fi
  [ -d "$dir" ] || lifecycle::fail "secrets: blueprint working tree not found: $dir"
  ( cd "$dir" && pwd )
}

# secrets::dest_path TARGET — the absolute file the secret will be written to. An
# absolute TARGET is taken as-is (place it anywhere); a relative one resolves
# against the blueprint working tree (so `secrets/<service>/<name>.age`, exactly as
# `secrets list` prints it, lands in the pool).
secrets::dest_path() {
  local target="$1" base
  case "$target" in
    /*) printf '%s\n' "$target" ;;
    # Standalone assignment, not an inline $() in printf's args: a lifecycle::fail
    # in blueprints_dir must propagate under set -e, not be masked by printf.
    *)  base="$(secrets::blueprints_dir)"
        printf '%s/%s\n' "$base" "$target" ;;
  esac
}

# secrets::place RECIPIENT DEST — encrypt stdin to RECIPIENT and write the
# ciphertext to DEST, creating parent dirs. The encrypt-and-place core; the caller
# arranges the plaintext on stdin and has already settled any overwrite. Writes
# via a temp + rename so a mid-encrypt failure never truncates an existing secret.
secrets::place() {
  local recipient="$1" dest="$2" dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.mk-secret.XXXXXX")
  if age::encrypt "$recipient" > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# secrets::place_file SRC DEST — copy SRC verbatim to DEST, creating parent dirs.
# For an already-encrypted secret that must NOT be re-encrypted (see secrets::put):
# the ciphertext is filed as-is. Temp + rename, like secrets::place, so a failed
# copy never truncates an existing secret.
secrets::place_file() {
  local src="$1" dest="$2" dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.mk-secret.XXXXXX")
  if cp "$src" "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# secrets::install_secret_file DEST PRODUCER [ARGS...] — run PRODUCER (a command),
# capturing its stdout into DEST as a mode-600 file, and only when the result is
# non-empty. Writes to a sibling tempfile and renames on success, so a producer
# that fails, is interrupted, or resolves nothing (e.g. a network fetch of a
# manager-backed secret) never truncates an existing DEST or leaves a zero-byte
# file a later `-f` check would bless. Returns 1 with DEST untouched on any of
# those, so the caller phrases the domain error. The caller creates DEST's dir.
secrets::install_secret_file() {
  local dest="$1"; shift
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  if "$@" > "$tmp" && [ -s "$tmp" ]; then
    chmod 600 "$tmp"
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}
