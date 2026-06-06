#!/usr/bin/env bash
# Module dependency resolver — DFS topological sort with cycle detection.
[ -n "${_MK_RESOLVER_LOADED:-}" ] && return 0
_MK_RESOLVER_LOADED=1

_resolver_visited=""
_resolver_in_progress=""
_resolver_result=()

resolver::resolve() {
  _resolver_visited=""
  _resolver_in_progress=""
  _resolver_result=()
  local mod
  for mod in "$@"; do
    resolver::_visit "$mod"
  done
  if [ "${#_resolver_result[@]}" -gt 0 ]; then
    printf '%s\n' "${_resolver_result[@]}"
  fi
}

resolver::_visit() {
  local mod="$1"
  case " $_resolver_visited "    in *" $mod "*) return 0 ;; esac
  case " $_resolver_in_progress " in *" $mod "*)
    lifecycle::fail "resolver: circular dependency detected involving '$mod'"
  esac
  _resolver_in_progress="$_resolver_in_progress $mod"
  if declare -f "${mod}::requires" > /dev/null 2>&1; then
    local dep
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      resolver::_visit "$dep"
    done < <("${mod}::requires")
  fi
  _resolver_in_progress="${_resolver_in_progress/ $mod/}"
  _resolver_visited="$_resolver_visited $mod"
  _resolver_result+=("$mod")
}
