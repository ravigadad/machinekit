#!/usr/bin/env bash
# Home sync — composes a merged staging dir and applies it to $HOME.
#
# The staging dir is built by layering each active module's templates,
# then the blueprint's common/home/ on top. Files are decoded from
# chezmoi naming conventions (dot_ → ., private_ → mode 600/700,
# .tmpl → render via gomplate) into an absolute destination — normally under
# $HOME, or under ${XDG_CONFIG_HOME:-$HOME/.config} when the root component is
# the xdg_config prefix — and written there.
[ -n "${_MK_HOME_LOADED:-}" ] && return 0
_MK_HOME_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/dry_run.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/staging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/transforms.sh"

_MK_HOME_STAGING_DIR=""

# Scratch variables set by home::_decode_path and consumed by
# _apply_file / _render_to_outdir in the same call frame.
_MK_HOME_DEST_PATH=""
_MK_HOME_IS_PRIVATE=0

# --- Public API ---

# The staging dir is built in preflight (so modules can query it via will_exist
# before anything is installed); sync only applies it.
home::sync() {
  if input::is_dry_run; then
    home::dry_run::show_diff
    return 0
  fi
  home::_apply
}

# home::will_exist DEST_PATH — true if the absolute DEST_PATH will exist after
# sync. Lets a module preflight depend on a home file by its final absolute path
# (e.g. "${XDG_CONFIG_HOME:-$HOME/.config}/foo"), not the blueprint's
# private_/.age encoding. Precondition: staging is built.
home::will_exist() {
  local dest_path="$1"
  [ -e "$dest_path" ] && return 0

  local staging ignore_file src src_rel
  staging="$(home::staging::dir)"
  ignore_file="$staging/.mkignore"

  while IFS= read -r src; do
    src_rel="${src#"$staging"/}"
    home::_decode_path "$src_rel"
    home::transforms::resolve "$_MK_HOME_DEST_PATH"
    [ "$_MK_HOME_TRANSFORM_DEST" = "$dest_path" ] || continue
    # The staged file maps to the query; it lands unless mkignore suppresses it.
    if [ -f "$ignore_file" ] && \
       grep -qxF "$(home::_dest_key "$dest_path")" "$ignore_file" 2>/dev/null; then
      return 1
    fi
    return 0
  done < <(find "$staging" -type f)
  return 1
}

# --- _apply and helpers ---

home::_apply() {
  local staging src_path
  staging="$(home::staging::dir)"
  logging::step "Applying home files"
  while IFS= read -r src_path; do
    home::_apply_file "$src_path" "$staging"
  done < <(find "$staging" -type f | sort)
  logging::success "Home files applied."
}

# Apply a single staging file to $HOME: decode its addressing, resolve its
# content pipeline, then (unless ignored) run the pipeline and reconcile the
# result. Resolve is parse-only, so an ignored file is never executed.
home::_apply_file() {
  local src="$1" staging="$2"
  local src_rel dest_path dest_key is_private

  src_rel="${src#"$staging"/}"
  home::_decode_path "$src_rel"
  is_private="$_MK_HOME_IS_PRIVATE"

  home::transforms::resolve "$_MK_HOME_DEST_PATH"
  dest_path="$_MK_HOME_TRANSFORM_DEST"
  dest_key="$(home::_dest_key "$dest_path")"

  [ "$dest_key" = ".mkignore" ] && return 0

  local ignore_file="$staging/.mkignore"
  if [ -f "$ignore_file" ] && grep -qxF "$dest_key" "$ignore_file" 2>/dev/null; then
    logging::debug "home: skipping $dest_key (mkignore)"
    return 0
  fi

  mkdir -p "$(dirname "$dest_path")"
  home::_apply_parent_perms "$src_rel" "$dest_path"

  home::transforms::execute "$src"
  home::_reconcile_file "$_MK_HOME_TRANSFORM_CONTENT" "$dest_path" "$dest_key" "$is_private"
}

# home::_decode_path REL_PATH
# Decodes a staging-dir relative path into the ABSOLUTE destination. Addressing
# prefixes (dot_/private_) decode per component; the root-only xdg_config prefix
# re-roots the remainder at ${XDG_CONFIG_HOME:-$HOME/.config} (which may lie
# outside $HOME), everything else at $HOME. Content-suffix markers like .tmpl
# are owned by home::transforms and left intact here. Sets module-scope
# variables consumed by _apply_file / _render_to_outdir in the same call frame:
#   _MK_HOME_DEST_PATH   absolute destination, e.g. "$HOME/.ssh/config" (markers intact)
#   _MK_HOME_IS_PRIVATE  1 if any component had the private_ prefix, else 0
home::_decode_path() {
  local rel="$1"
  local decoded="" remainder="$rel" comp first=1 base="$HOME"
  _MK_HOME_IS_PRIVATE=0

  while [ -n "$remainder" ]; do
    comp="${remainder%%/*}"
    remainder="${remainder#"$comp"}"
    remainder="${remainder#/}"

    # xdg_config re-roots the rest at the XDG config dir; only meaningful as the
    # first component (the config-dir root).
    if [ "$first" = 1 ] && [ "$comp" = "xdg_config" ]; then
      base="${XDG_CONFIG_HOME:-$HOME/.config}"
      first=0
      continue
    fi
    first=0

    if [ "${comp#private_}" != "$comp" ]; then
      _MK_HOME_IS_PRIVATE=1
      comp="${comp#private_}"
    fi
    if [ "${comp#dot_}" != "$comp" ]; then
      comp=".${comp#dot_}"
    fi

    if [ -z "$decoded" ]; then decoded="$comp"; else decoded="$decoded/$comp"; fi
  done

  _MK_HOME_DEST_PATH="$base/$decoded"
}

# home::_dest_key ABS_PATH
# The portable key for an absolute destination: $HOME-relative when the path is
# under $HOME (the common case, including the default XDG dir), else the path
# itself. Drives .mkignore matching and the conflict/diff display labels — an
# XDG dir relocated outside $HOME has no $HOME-relative form, so it keys by its
# absolute path (an .mkignore on such a path is then machine-specific).
home::_dest_key() {
  local abs="$1"
  case "$abs" in
    "$HOME"/*) printf '%s\n' "${abs#"$HOME"/}" ;;
    *)         printf '%s\n' "$abs" ;;
  esac
}

home::_apply_parent_perms() {
  local src_rel="$1" dest_path="$2"
  case "$src_rel" in
    */*)
      local parent_staging_name="${src_rel%/*}"
      parent_staging_name="${parent_staging_name##*/}"
      if [ "${parent_staging_name#private_}" != "$parent_staging_name" ]; then
        chmod 700 "$(dirname "$dest_path")"
      fi
      ;;
  esac
}

home::_reconcile_file() {
  local resolved="$1" dest_path="$2" dest_rel="$3" is_private="$4"
  if [ ! -f "$dest_path" ]; then
    home::_write_file "$resolved" "$dest_path" "$is_private"
    logging::debug "home: applied $dest_rel"
  elif cmp -s "$resolved" "$dest_path" 2>/dev/null; then
    rm -f -- "$resolved"
    logging::debug "home: unchanged $dest_rel"
  else
    if ! home::_conflict_action "$dest_rel" "$resolved" "$dest_path"; then
      rm -f -- "$resolved"
      logging::debug "home: skipped $dest_rel"
      return 0
    fi
    home::_write_file "$resolved" "$dest_path" "$is_private"
    logging::debug "home: applied $dest_rel"
  fi
}

home::_write_file() {
  local resolved="$1" dest_path="$2" is_private="$3"
  cp -- "$resolved" "$dest_path"
  rm -f -- "$resolved"
  if [ "$is_private" = "1" ]; then
    chmod 600 "$dest_path"
  fi
}

# Returns 0 (overwrite) or 1 (skip). Calls lifecycle::fail for abort.
home::_conflict_action() {
  local dest_rel="$1" resolved_path="$2" dest_path="$3"
  local behavior
  behavior=$(input::conflict_behavior)

  if [ -z "$behavior" ]; then
    if input::is_interactive >/dev/null; then
      local decision
      while true; do
        decision=$(home::_prompt_conflict "$dest_rel")
        case "$decision" in
          overwrite)     return 0 ;;
          skip)          return 1 ;;
          abort)         lifecycle::fail "home: aborted by user on '${dest_rel}'" ;;
          diff)          home::_show_conflict_diff "$resolved_path" "$dest_path" ;;
          overwrite-all) export MACHINEKIT_CONFLICT_BEHAVIOR=overwrite; return 0 ;;
          skip-all)      export MACHINEKIT_CONFLICT_BEHAVIOR=skip; return 1 ;;
        esac
      done
    else
      behavior="overwrite"
    fi
  fi

  case "$behavior" in
    overwrite) return 0 ;;
    skip)      return 1 ;;
    abort)     lifecycle::fail "home: conflict on '${dest_rel}' — aborting" ;;
    *)         lifecycle::fail "home: unknown conflict_behavior '${behavior}'" ;;
  esac
}

home::_prompt_conflict() {
  local dest_rel="$1"
  local choice display
  # Display label only; the literal ~ is intentional, not a path to expand.
  # shellcheck disable=SC2088
  case "$dest_rel" in
    /*) display="$dest_rel" ;;
    *)  display="~/$dest_rel" ;;
  esac
  while true; do
    logging::attention "file exists and differs: ${MK_COLOR_BOLD}${display}${MK_COLOR_RESET}"
    printf '  [o] overwrite        write machinekit'"'"'s version\n' >&2
    printf '  [s] skip             keep your current version\n' >&2
    printf '  [a] abort            stop and exit\n' >&2
    printf '  [d] diff             show the diff, then decide\n' >&2
    printf '  [O] overwrite all    overwrite this and all remaining conflicts\n' >&2
    printf '  [S] skip all         skip this and all remaining conflicts\n' >&2
    choice=$(home::_read_conflict_choice)
    case "$choice" in
      o) printf 'overwrite\n';     return 0 ;;
      s) printf 'skip\n';          return 0 ;;
      a) printf 'abort\n';         return 0 ;;
      d) printf 'diff\n';          return 0 ;;
      O) printf 'overwrite-all\n'; return 0 ;;
      S) printf 'skip-all\n';      return 0 ;;
      *) logging::warn "home: invalid choice '${choice}', try again" ;;
    esac
  done
}

# Seam for interactive conflict tests.
home::_read_conflict_choice() {
  local choice
  read -r -n 1 choice <"${MACHINEKIT_TTY:-/dev/tty}"
  printf '\n' >&2
  printf '%s\n' "$choice"
}

home::_show_conflict_diff() {
  local resolved_path="$1" dest_path="$2"
  local diff_file
  diff_file=$(mktemp)
  git diff --no-index --color=always "$dest_path" "$resolved_path" 2>/dev/null > "$diff_file" || true
  if [ -s "$diff_file" ]; then
    less -R "$diff_file"
  fi
  rm -f -- "$diff_file"
}
