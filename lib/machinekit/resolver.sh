#!/usr/bin/env bash
# Module dependency resolver — DFS topological sort with cycle detection.
#
# Two edge kinds:
#   ::requires  hard dependency — pulls the target into the active set and orders
#               it before this module.
#   ::after     soft ordering edge — orders this module after the target only when
#               the target is *independently* active; never activates it. Use it
#               for "run after X when X is also present" without coupling the two
#               (an ::after to an inactive module is silently ignored).
[ -n "${_MK_RESOLVER_LOADED:-}" ] && return 0
_MK_RESOLVER_LOADED=1

_resolver_visited=""
_resolver_in_progress=""
_resolver_result=()
_resolver_requested=()
_resolver_active=""
_resolver_apply_after=0

resolver::resolve() {
  _resolver_requested=("$@")

  # Pass 1 — the active set (requires only).
  resolver::_run_pass 0
  if [ "${#_resolver_result[@]}" -gt 0 ]; then
    _resolver_active=" ${_resolver_result[*]} "
  else
    _resolver_active=" "
  fi

  # Pass 2 — final order, now applying after edges over that active set.
  resolver::_run_pass 1

  resolver::_check_conflicts
  if [ "${#_resolver_result[@]}" -gt 0 ]; then
    printf '%s\n' "${_resolver_result[@]}"
  fi
}

# One DFS pass; apply_after gates whether after edges are followed (0 for pass 1,
# which establishes the active set; 1 for pass 2).
resolver::_run_pass() {
  _resolver_apply_after="$1"
  _resolver_visited=""
  _resolver_in_progress=""
  _resolver_result=()
  [ "${#_resolver_requested[@]}" -gt 0 ] || return 0
  local mod
  for mod in "${_resolver_requested[@]}"; do
    resolver::_visit "$mod"
  done
}

resolver::_visit() {
  local mod="$1"
  case " $_resolver_visited "    in *" $mod "*) return 0 ;; esac
  case " $_resolver_in_progress " in *" $mod "*)
    lifecycle::fail "resolver: circular dependency detected involving '$mod'"
  esac
  _resolver_in_progress="$_resolver_in_progress $mod"

  # For capability modules, an explicit satisfier in the requested list takes
  # precedence over the default. Skip ::requires entirely when one is found so
  # the default satisfier is not also pulled in.
  local skip_requires=0
  if declare -f "${mod}::is_capability" > /dev/null 2>&1 && "${mod}::is_capability"; then
    local satisfier
    satisfier=$(resolver::_find_explicit_satisfier "$mod")
    if [ -n "$satisfier" ]; then
      resolver::_visit "$satisfier"
      skip_requires=1
    fi
  fi

  if [ "$skip_requires" -eq 0 ] && declare -f "${mod}::requires" > /dev/null 2>&1; then
    local dep

    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      resolver::_visit "$dep"
    done < <("${mod}::requires")
  fi

  # after edges, pass 2 only. Gating on the active set is what makes after
  # ordering-only: an inactive target is skipped, never pulled in.
  if [ "$_resolver_apply_after" -eq 1 ] && declare -f "${mod}::after" > /dev/null 2>&1; then
    local after_target
    while IFS= read -r after_target; do
      [ -n "$after_target" ] || continue
      case " $_resolver_active " in
        *" $after_target "*) resolver::_visit "$after_target" ;;
      esac
    done < <("${mod}::after")
  fi

  _resolver_in_progress="${_resolver_in_progress/ $mod/}"
  _resolver_visited="$_resolver_visited $mod"
  _resolver_result+=("$mod")
}

# Returns the first module in _resolver_requested that provides the given
# capability, or nothing if none do.
resolver::_find_explicit_satisfier() {
  local capability="$1" req provided
  for req in "${_resolver_requested[@]}"; do
    declare -f "${req}::provides" > /dev/null 2>&1 || continue
    while IFS= read -r provided; do
      [ "$provided" = "$capability" ] && printf '%s\n' "$req" && return 0
    done < <("${req}::provides")
  done
  # "No explicit satisfier" is a normal answer, signalled by empty stdout — not a
  # failure. Return success explicitly so the loop's trailing nonzero (a false
  # provides-match on the last requested module) can't leak out: _visit assigns
  # this via satisfier=$(...) under set -e, where a nonzero status aborts resolve.
  return 0
}

# Scans resolved modules for ::provides declarations. Fails if two modules
# claim the same capability, unless allow_multiple_satisfiers is configured.
resolver::_check_conflicts() {
  local mod provided all_provided="" seen_caps="" cap count satisfier_names allow

  for mod in "${_resolver_result[@]}"; do
    declare -f "${mod}::provides" > /dev/null 2>&1 || continue
    while IFS= read -r provided; do
      [ -n "$provided" ] || continue
      all_provided="$all_provided $provided"
    done < <("${mod}::provides")
  done

  for cap in $all_provided; do
    case " $seen_caps " in *" $cap "*) continue ;; esac
    seen_caps="$seen_caps $cap"

    count=0
    satisfier_names=""
    for mod in "${_resolver_result[@]}"; do
      declare -f "${mod}::provides" > /dev/null 2>&1 || continue
      while IFS= read -r provided; do
        [ "$provided" = "$cap" ] || continue
        count=$((count + 1))
        satisfier_names="$satisfier_names $mod"
        break
      done < <("${mod}::provides")
    done

    if [ "$count" -ge 2 ]; then
      allow=$(config::get "capability.${cap}.allow_multiple_satisfiers" 2>/dev/null || true)
      [ "$allow" = "true" ] && continue
      lifecycle::fail "resolver: conflict —$(printf '%s' "$satisfier_names") both satisfy '${cap}'. Remove one or set [capability.${cap}] allow_multiple_satisfiers = true."
    fi
  done
}
