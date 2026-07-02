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
# (secrets/<service>/...); the single source of the prefix.
_MK_SECRETS_POOL_REL="secrets"

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

# secrets::needed — every pool secret the active modules declare they will use,
# as `path<TAB>required<TAB>can_be_generated` lines (the latter two booleans,
# "true"/"false"). The union across active modules' pool_secrets hooks, resolved
# against current context (a module emits only the secrets it will actually use on
# this machine).
secrets::needed() {
  modules::collect pool_secrets
}

# secrets::inventory — the secrets the active modules declare, joined with whether
# each is in the pool: `path<TAB>required<TAB>can_be_generated<TAB>state` rows, one
# per declared secret, sorted by path. required and can_be_generated are the
# booleans the module declared; state is `provided` (present in the pool) or
# `missing`. Pool secrets no module declares are not here — see secrets::orphans.
secrets::inventory() {
  local -A required=() can_be_generated=() present=()
  local path req gen

  while IFS=$'\t' read -r path req gen; do
    [ -n "$path" ] || continue
    required["$path"]="$req"
    can_be_generated["$path"]="$gen"
  done < <(secrets::needed)

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    present["$path"]=1
  done < <(secrets::in_pool)

  for path in "${!required[@]}"; do printf '%s\n' "$path"; done \
    | sort | while IFS= read -r path; do
    if [ -n "${present[$path]:-}" ]; then
      printf '%s\t%s\t%s\tprovided\n' "$path" "${required[$path]}" "${can_be_generated[$path]}"
    else
      printf '%s\t%s\t%s\tmissing\n' "$path" "${required[$path]}" "${can_be_generated[$path]}"
    fi
  done
}

# secrets::orphans — pool secrets no active module declares, one path per line,
# sorted. Usually a typo or a stale entry; surfaced apart from the inventory so a
# stray pool file is flagged rather than presented as something a module needs.
secrets::orphans() {
  local -A declared=()
  local path
  while IFS=$'\t' read -r path _; do
    [ -n "$path" ] || continue
    declared["$path"]=1
  done < <(secrets::needed)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -n "${declared[$path]:-}" ] || printf '%s\n' "$path"
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
