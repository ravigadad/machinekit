#!/usr/bin/env bash
# secrets — the blueprint secrets pool: what it currently holds, and what the
# active modules say they need. Read-only inventory; encryption and placement of
# new secrets are not handled here.
[ -n "${_MK_SECRETS_LOADED:-}" ] && return 0
_MK_SECRETS_LOADED=1

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
