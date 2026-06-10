#!/usr/bin/env bash
# Home transforms — the content-representation pipeline for home files.
#
# A staging filename encodes two orthogonal things: addressing (prefixes like
# dot_/private_, owned by home::_decode_path) and content representation (suffix
# markers like .tmpl/.age, owned here). A marker is a registered extension
# bound to a tier and a handler. Decode-tier markers (decrypt, decompress) must
# be the outermost suffixes; content-tier markers (templating) operate on
# already-readable content. The registry is built in preflight from the active
# modules' file_transforms hooks, so a marker whose module is inactive is never
# registered and its file is copied verbatim.
[ -n "${_MK_HOME_TRANSFORMS_LOADED:-}" ] && return 0
_MK_HOME_TRANSFORMS_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../home.sh"

# Registry: three parallel indexed arrays keyed by position (bash 3.2 has no
# associative arrays; collapses to one map at the bash 5.3 iteration).
_MK_HOME_TRANSFORM_EXTS=()
_MK_HOME_TRANSFORM_TIERS=()
_MK_HOME_TRANSFORM_FNS=()

# Per-file scratch, set by _parse / _execute and read by the caller.
_MK_HOME_TRANSFORM_PIPELINE=()
_MK_HOME_TRANSFORM_DEST=""
_MK_HOME_TRANSFORM_CONTENT=""

# Temp files produced during execution. Run-scoped, not per-file: intermediates
# are removed eagerly as they are spent and each final temp is the caller's to
# free once written, so this holds mostly already-deleted paths. It exists as the
# exit-trap backstop that cleans up whatever is still in flight if a handler dies
# mid-chain — not a leak.
_MK_HOME_TRANSFORM_TEMPS=()

# --- Public API ---

# register EXT TIER FN — bind a file extension to a pipeline stage.
# Tier must be decode or content. An extension maps to exactly one (tier, fn):
# a divergent claim is an unresolvable conflict (the same bytes can't be decoded
# two different ways), while an identical re-claim is a harmless duplicate.
home::transforms::register() {
  local ext="$1" tier="$2" fn="$3"
  case "$tier" in
    decode|content) ;;
    *) lifecycle::fail "home::transforms::register: invalid tier '$tier' for '.$ext' (expected 'decode' or 'content')" ;;
  esac
  local idx
  if idx=$(home::transforms::_index_of "$ext"); then
    if [ "${_MK_HOME_TRANSFORM_TIERS[idx]}" = "$tier" ] && [ "${_MK_HOME_TRANSFORM_FNS[idx]}" = "$fn" ]; then
      logging::debug "home::transforms: '.$ext' already registered to $fn; ignoring duplicate"
      return 0
    fi
    lifecycle::fail "home::transforms::register: extension '.$ext' is claimed by both ${_MK_HOME_TRANSFORM_FNS[idx]} and $fn"
  fi
  _MK_HOME_TRANSFORM_EXTS+=("$ext")
  _MK_HOME_TRANSFORM_TIERS+=("$tier")
  _MK_HOME_TRANSFORM_FNS+=("$fn")
}

# Populate the registry from the active modules' file_transforms hooks. Additive,
# so any directly-registered framework transforms are preserved. Each hook emits
# "ext tier fn" lines; modules without the hook contribute nothing.
home::transforms::register_from_modules() {
  modules::source_all
  local mod line fields
  while IFS= read -r mod; do
    [ -z "$mod" ] && continue
    declare -F "${mod}::file_transforms" > /dev/null 2>&1 || continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      read -r -a fields <<< "$line"
      [ "${#fields[@]}" -eq 3 ] || lifecycle::fail "home::transforms: ${mod}::file_transforms emitted a malformed line (expected 'ext tier fn'): '$line'"
      home::transforms::register "${fields[0]}" "${fields[1]}" "${fields[2]}"
    done < <("${mod}::file_transforms")
  done < <(context::get_array "modules.active")
}

# lookup EXT — print "TIER FN" for a registered extension; nonzero if unknown.
home::transforms::lookup() {
  local ext="$1" idx
  idx=$(home::transforms::_index_of "$ext") || return 1
  printf '%s %s\n' "${_MK_HOME_TRANSFORM_TIERS[idx]}" "${_MK_HOME_TRANSFORM_FNS[idx]}"
}

# resolve DEST_REL — parse only. Peel registered suffix markers off DEST_REL
# right-to-left (envelope order) into _MK_HOME_TRANSFORM_PIPELINE (execution
# order) and the final _MK_HOME_TRANSFORM_DEST (suffixes stripped). Runs no
# handlers, so the caller can decide to skip a file (e.g. mkignore) before
# paying to execute it. The first unregistered extension is terminal and kept;
# enforces the cross-tier law: decode markers must be outermost, so no decode
# stage may follow a content one.
home::transforms::resolve() {
  local dest_rel="$1"
  local dir base
  case "$dest_rel" in
    */*) dir="${dest_rel%/*}"; base="${dest_rel##*/}" ;;
    *)   dir="";              base="$dest_rel" ;;
  esac

  _MK_HOME_TRANSFORM_PIPELINE=()
  local seen_content=0 stem ext tier_fn tier fn
  while :; do
    stem="${base%.*}"
    ext="${base##*.}"
    # Peel only a real stem.ext split: a leading dot is a dotfile marker (not a
    # separator), and a trailing dot has no extension. Either would otherwise
    # collapse the destination — e.g. '.tmpl' must stay '.tmpl', not become ''.
    { [ "$stem" != "$base" ] && [ -n "$stem" ] && [ -n "$ext" ]; } || break
    tier_fn=$(home::transforms::lookup "$ext") || break
    tier="${tier_fn%% *}"
    fn="${tier_fn#* }"
    if [ "$tier" = "decode" ] && [ "$seen_content" = "1" ]; then
      lifecycle::fail "home::transforms: '$dest_rel' applies a decode transform ('.$ext') after a content transform; decode markers must be the outermost suffixes"
    fi
    [ "$tier" = "content" ] && seen_content=1
    _MK_HOME_TRANSFORM_PIPELINE+=("$fn")
    base="$stem"
  done

  if [ -n "$dir" ]; then
    _MK_HOME_TRANSFORM_DEST="$dir/$base"
  else
    _MK_HOME_TRANSFORM_DEST="$base"
  fi
}

# execute SRC — run the pipeline that resolve() built over SRC, leaving the
# result in _MK_HOME_TRANSFORM_CONTENT (a temp the caller consumes). Stages are
# chained via redirection, never command substitution, so a handler's memoized
# state (e.g. gomplate's context) survives across files. Intermediates are
# removed as they are spent.
home::transforms::execute() {
  local src="$1"
  local in="$src" tmp fn stages
  # No transforms still must yield a fresh temp; the identity copy (cat) does it
  # and shares the uniform "IN > OUT" handler signature, so an empty pipeline is
  # just a one-stage pipeline — no separate copy path. (The if/else avoids
  # expanding an empty array, which errors under `set -u` in bash 3.2.)
  if [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 0 ]; then
    stages=(cat)
  else
    stages=("${_MK_HOME_TRANSFORM_PIPELINE[@]}")
  fi

  for fn in "${stages[@]}"; do
    tmp=$(mktemp)
    home::transforms::_track_temp "$tmp"
    # Abort explicitly rather than relying on the caller's `set -e` context — a
    # suppressed failure would feed a partial temp into the next stage and write
    # corrupt content. Tracked temps are cleaned up by the exit trap.
    "$fn" "$in" > "$tmp" || lifecycle::fail "home::transforms: stage '$fn' failed on '$in'"
    [ "$in" != "$src" ] && rm -f -- "$in"
    in="$tmp"
  done
  _MK_HOME_TRANSFORM_CONTENT="$in"
}

# --- Internals ---

# Print the registry index of EXT, or return nonzero if it is not registered.
home::transforms::_index_of() {
  local ext="$1" n i
  n=${#_MK_HOME_TRANSFORM_EXTS[@]}
  for (( i = 0; i < n; i++ )); do
    if [ "${_MK_HOME_TRANSFORM_EXTS[i]}" = "$ext" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

home::transforms::_track_temp() {
  _MK_HOME_TRANSFORM_TEMPS+=("$1")
  if [ -z "${_MK_HOME_TRANSFORM_CLEANUP_REGISTERED:-}" ]; then
    lifecycle::register_cleanup home::transforms::_cleanup_temps
    _MK_HOME_TRANSFORM_CLEANUP_REGISTERED=1
  fi
}

home::transforms::_cleanup_temps() {
  [ "${#_MK_HOME_TRANSFORM_TEMPS[@]}" -gt 0 ] || return 0
  local t
  for t in "${_MK_HOME_TRANSFORM_TEMPS[@]}"; do
    rm -f -- "$t"
  done
  _MK_HOME_TRANSFORM_TEMPS=()
}
