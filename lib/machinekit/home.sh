#!/usr/bin/env bash
# Home sync — composes a merged staging dir and applies it to $HOME.
#
# The staging dir is built by layering each active module's templates,
# then the blueprint's common/home/ on top. Files are decoded from
# chezmoi naming conventions (dot_ → ., private_ → mode 600/700,
# .tmpl → render via gomplate) and written to $HOME.
[ -n "${_MK_HOME_LOADED:-}" ] && return 0
_MK_HOME_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/dry_run.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/staging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/transforms.sh"

_MK_HOME_STAGING_DIR=""

# Scratch variables set by home::_decode_path and consumed by
# _apply_file / _render_to_outdir in the same call frame.
_MK_HOME_DEST_REL=""
_MK_HOME_IS_PRIVATE=0

# --- Public API ---

home::sync() {
  home::staging::build
  if input::is_dry_run; then
    home::dry_run::show_diff
    return 0
  fi
  home::_apply
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
  local src_rel dest_rel dest_path is_private

  src_rel="${src#"$staging"/}"
  home::_decode_path "$src_rel"
  is_private="$_MK_HOME_IS_PRIVATE"

  home::transforms::resolve "$_MK_HOME_DEST_REL"
  dest_rel="$_MK_HOME_TRANSFORM_DEST"

  [ "$dest_rel" = ".mkignore" ] && return 0

  local ignore_file="$staging/.mkignore"
  if [ -f "$ignore_file" ] && grep -qxF "$dest_rel" "$ignore_file" 2>/dev/null; then
    logging::debug "home: skipping $dest_rel (mkignore)"
    return 0
  fi

  dest_path="$HOME/$dest_rel"
  mkdir -p "$(dirname "$dest_path")"
  home::_apply_parent_perms "$src_rel" "$dest_path"

  home::transforms::execute "$src"
  home::_reconcile_file "$_MK_HOME_TRANSFORM_CONTENT" "$dest_path" "$dest_rel" "$is_private"
}

# home::_decode_path REL_PATH
# Decodes the addressing of a staging-dir relative path into the $HOME-relative
# destination. Prefixes only (dot_/private_); content-suffix markers like .tmpl
# are owned by home::transforms and left intact here. Sets module-scope
# variables consumed by _apply_file / _render_to_outdir in the same call frame:
#   _MK_HOME_DEST_REL    decoded path, e.g. ".ssh/config" (markers intact)
#   _MK_HOME_IS_PRIVATE  1 if any component had the private_ prefix, else 0
home::_decode_path() {
  local rel="$1"
  local result="" remainder="$rel" comp
  _MK_HOME_IS_PRIVATE=0

  while [ -n "$remainder" ]; do
    comp="${remainder%%/*}"
    remainder="${remainder#"$comp"}"
    remainder="${remainder#/}"

    if [ "${comp#private_}" != "$comp" ]; then
      _MK_HOME_IS_PRIVATE=1
      comp="${comp#private_}"
    fi
    if [ "${comp#dot_}" != "$comp" ]; then
      comp=".${comp#dot_}"
    fi

    if [ -z "$result" ]; then result="$comp"; else result="$result/$comp"; fi
  done

  _MK_HOME_DEST_REL="$result"
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
  local choice
  while true; do
    logging::attention "file exists and differs: ${MK_COLOR_BOLD}~/${dest_rel}${MK_COLOR_RESET}"
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
