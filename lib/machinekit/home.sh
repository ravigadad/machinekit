#!/usr/bin/env bash
# Home sync — composes a merged staging dir and applies it to $HOME.
#
# The staging dir is built by layering each active module's templates,
# then the blueprint's common/home/ on top. Files are decoded from
# chezmoi naming conventions (dot_ → ., private_ → mode 600/700,
# .tmpl → render via gomplate) and written to $HOME.
[ -n "${_MK_HOME_LOADED:-}" ] && return 0
_MK_HOME_LOADED=1

_MK_HOME_STAGING_DIR=""
_MK_HOME_CTX_FILE=""

# Scratch variables set by home::_decode_path and consumed by
# _apply_file / _render_to_outdir in the same call frame.
_MK_HOME_DEST_REL=""
_MK_HOME_IS_PRIVATE=0
_MK_HOME_IS_TEMPLATE=0

home::_cleanup_ctx() {
  [ -n "$_MK_HOME_CTX_FILE" ] || return 0
  rm -f -- "$_MK_HOME_CTX_FILE"
  _MK_HOME_CTX_FILE=""
}

home::staging_dir() {
  [ -n "$_MK_HOME_STAGING_DIR" ] || \
    lifecycle::fail "home::staging_dir called before home::build_staging"
  printf '%s\n' "$_MK_HOME_STAGING_DIR"
}

home::build_staging() {
  home::_prepare_staging_dir
  logging::step "Building home staging dir"

  local module
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    home::_layer_dir "$(modules::dir)/$module/templates" "$module templates"
  done < <(context::get_array "modules.active" || true)

  home::_layer_dir "$(blueprints::dir)/common/home" "blueprint common/home"

  logging::success "Staging dir built at $_MK_HOME_STAGING_DIR"
}

home::_prepare_staging_dir() {
  if input::is_dry_run; then
    _MK_HOME_STAGING_DIR=$(mktemp -d)
    lifecycle::register_cleanup home::cleanup_staging
  else
    _MK_HOME_STAGING_DIR="$HOME/.local/share/machinekit/staging"
    rm -rf -- "$_MK_HOME_STAGING_DIR"
    mkdir -p "$_MK_HOME_STAGING_DIR"
  fi
}

home::_layer_dir() {
  local src="$1" label="$2"
  [ -d "$src" ] || return 0
  cp -R -- "$src"/. "$_MK_HOME_STAGING_DIR/"
  logging::debug "staging: layered $label"
}

home::cleanup_staging() {
  [ -n "$_MK_HOME_STAGING_DIR" ] || return 0
  rm -rf -- "$_MK_HOME_STAGING_DIR"
  _MK_HOME_STAGING_DIR=""
}

home::sync() {
  home::build_staging
  if input::is_dry_run; then
    home::_diff
    return 0
  fi
  home::_apply
}

home::_apply() {
  local staging src_path
  staging="$(home::staging_dir)"

  _MK_HOME_CTX_FILE=$(mktemp)
  context::json > "$_MK_HOME_CTX_FILE"
  lifecycle::register_cleanup home::_cleanup_ctx

  logging::step "Applying home files"

  while IFS= read -r src_path; do
    home::_apply_file "$src_path" "$staging" "$_MK_HOME_CTX_FILE"
  done < <(find "$staging" -type f | sort)

  home::_cleanup_ctx
  logging::success "Home files applied."
}

# Apply a single staging file to $HOME, decoding the path and permissions.
home::_apply_file() {
  local src="$1" staging="$2" ctx_file="$3"
  local src_rel dest_rel dest_path is_private is_template

  src_rel="${src#$staging/}"
  home::_decode_path "$src_rel"
  dest_rel="$_MK_HOME_DEST_REL"
  is_private="$_MK_HOME_IS_PRIVATE"
  is_template="$_MK_HOME_IS_TEMPLATE"

  [ "$dest_rel" = ".mkignore" ] && return 0

  local ignore_file="$staging/.mkignore"
  if [ -f "$ignore_file" ] && grep -qxF "$dest_rel" "$ignore_file" 2>/dev/null; then
    logging::debug "home: skipping $dest_rel (mkignore)"
    return 0
  fi

  dest_path="$HOME/$dest_rel"
  mkdir -p "$(dirname "$dest_path")"

  # If the immediate parent directory in staging had a private_ prefix,
  # set the decoded directory to mode 700 (e.g. private_dot_ssh → ~/.ssh/).
  case "$src_rel" in
    */*)
      local parent_staging_name="${src_rel%/*}"
      parent_staging_name="${parent_staging_name##*/}"
      if [ "${parent_staging_name#private_}" != "$parent_staging_name" ]; then
        chmod 700 "$(dirname "$dest_path")"
      fi
      ;;
  esac

  if [ "$is_template" = "1" ]; then
    gomplate --context ".=file://${ctx_file}?type=application/json" \
      -f "$src" > "$dest_path"
  else
    cp -- "$src" "$dest_path"
  fi

  [ "$is_private" = "1" ] && chmod 600 "$dest_path"
  logging::debug "home: applied $dest_rel"
}

# home::_decode_path REL_PATH
# Decodes a staging-dir relative path into the $HOME-relative destination.
# Sets module-scope variables consumed by _apply_file / _render_to_outdir:
#   _MK_HOME_DEST_REL    decoded path, e.g. ".ssh/config"
#   _MK_HOME_IS_PRIVATE  1 if any component had the private_ prefix, else 0
#   _MK_HOME_IS_TEMPLATE 1 if the filename ends in .tmpl, else 0
home::_decode_path() {
  local rel="$1"
  local result="" remainder="$rel" comp
  _MK_HOME_IS_PRIVATE=0
  _MK_HOME_IS_TEMPLATE=0

  while [ -n "$remainder" ]; do
    comp="${remainder%%/*}"
    remainder="${remainder#$comp}"
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

  if [ "${result%.tmpl}" != "$result" ]; then
    _MK_HOME_IS_TEMPLATE=1
    result="${result%.tmpl}"
  fi

  _MK_HOME_DEST_REL="$result"
}

home::_diff() {
  local staging tmp_out src_path
  staging="$(home::staging_dir)"
  logging::step "home dry-run: diff against $HOME"

  tmp_out=$(mktemp -d)
  _MK_HOME_CTX_FILE=$(mktemp)
  context::json > "$_MK_HOME_CTX_FILE"
  lifecycle::register_cleanup home::_cleanup_ctx

  while IFS= read -r src_path; do
    home::_render_to_outdir "$src_path" "$staging" "$_MK_HOME_CTX_FILE" "$tmp_out"
  done < <(find "$staging" -type f | sort)

  home::_show_diff "$tmp_out"

  rm -rf -- "$tmp_out"
  home::_cleanup_ctx
}

home::_render_to_outdir() {
  local src="$1" staging="$2" ctx_file="$3" out_dir="$4"
  local src_rel dest_rel is_template out_path

  src_rel="${src#$staging/}"
  home::_decode_path "$src_rel"
  dest_rel="$_MK_HOME_DEST_REL"
  is_template="$_MK_HOME_IS_TEMPLATE"

  [ "$dest_rel" = ".mkignore" ] && return 0

  local ignore_file="$staging/.mkignore"
  if [ -f "$ignore_file" ] && grep -qxF "$dest_rel" "$ignore_file" 2>/dev/null; then
    return 0
  fi

  out_path="$out_dir/$dest_rel"
  mkdir -p "$(dirname "$out_path")"

  if [ "$is_template" = "1" ]; then
    gomplate --context ".=file://${ctx_file}?type=application/json" \
      -f "$src" > "$out_path"
  else
    cp -- "$src" "$out_path"
  fi
}

home::_show_diff() {
  local tmp_out="$1"
  if input::is_interactive; then
    home::_show_interactive_diff "$tmp_out"
  else
    home::_show_plain_diff "$tmp_out"
  fi
}

home::_show_interactive_diff() {
  local tmp_out="$1"
  local diff_file
  diff_file=$(mktemp)
  home::_generate_diff "$tmp_out" > "$diff_file"
  if [ ! -s "$diff_file" ]; then
    rm -f -- "$diff_file"
    logging::info "No changes to home files."
    return 0
  fi
  home::_page_diff "$diff_file"
  rm -f -- "$diff_file"
}

home::_page_diff() {
  local diff_file="$1"
  logging::info "  Unified diff format. In the pager: arrows/j/k scroll · / searches · q exits and continues."
  read -r -s -n 1 -p $'\n[machinekit] Press any key to open diff...' <"${MACHINEKIT_TTY:-/dev/tty}"
  printf '\n' >&2
  less -R "$diff_file"
}

home::_show_plain_diff() {
  local tmp_out="$1"
  local has_changes=0 out_path rel_path dest_path
  while IFS= read -r out_path; do
    rel_path="${out_path#$tmp_out/}"
    dest_path="$HOME/$rel_path"
    if [ ! -f "$dest_path" ]; then
      git diff --no-index --no-color /dev/null "$out_path" 2>/dev/null || true
      has_changes=1
    elif ! diff -q "$out_path" "$dest_path" >/dev/null 2>&1; then
      git diff --no-index --no-color "$dest_path" "$out_path" 2>/dev/null || true
      has_changes=1
    fi
  done < <(find "$tmp_out" -type f | sort)
  if [ "$has_changes" = "0" ]; then
    logging::info "No changes to home files."
  fi
}

home::_generate_diff() {
  local tmp_out="$1"
  local out_path rel_path dest_path
  while IFS= read -r out_path; do
    rel_path="${out_path#$tmp_out/}"
    dest_path="$HOME/$rel_path"
    if [ ! -f "$dest_path" ]; then
      git diff --no-index --color=always /dev/null "$out_path" 2>/dev/null || true
    elif ! diff -q "$out_path" "$dest_path" >/dev/null 2>&1; then
      git diff --no-index --color=always "$dest_path" "$out_path" 2>/dev/null || true
    fi
  done < <(find "$tmp_out" -type f | sort)
}
