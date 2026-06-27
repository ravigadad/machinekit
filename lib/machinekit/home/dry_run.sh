#!/usr/bin/env bash
# Home dry-run — when running dry-run, generates and presents a diff.
[ -n "${_MK_HOME_DRY_RUN_LOADED:-}" ] && return 0
_MK_HOME_DRY_RUN_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../home.sh"

home::dry_run::show_diff() {
  local staging tmp_out src_path
  staging="$(home::staging::dir)"
  logging::step "home dry-run: diff against $HOME"

  tmp_out=$(mktemp -d)

  while IFS= read -r src_path; do
    home::dry_run::_render_to_outdir "$src_path" "$staging" "$tmp_out"
  done < <(find "$staging" -type f | sort)

  home::dry_run::_show_diff "$tmp_out"

  rm -rf -- "$tmp_out"
}

home::dry_run::_render_to_outdir() {
  local src="$1" staging="$2" out_dir="$3"
  local src_rel dest_path dest_key out_path

  src_rel="${src#"$staging"/}"
  home::_decode_path "$src_rel"

  home::transforms::resolve "$_MK_HOME_DEST_PATH"
  dest_path="$_MK_HOME_TRANSFORM_DEST"
  dest_key="$(home::_dest_key "$dest_path")"

  [ "$dest_key" = ".mkignore" ] && return 0

  local ignore_file="$staging/.mkignore"
  if [ -f "$ignore_file" ] && grep -qxF "$dest_key" "$ignore_file" 2>/dev/null; then
    return 0
  fi

  # Mirror the absolute destination under the preview dir (leading slash
  # stripped); _generate_diff re-roots back to the real path by re-adding it.
  out_path="$out_dir/${dest_path#/}"
  mkdir -p "$(dirname "$out_path")"

  home::transforms::execute "$src"
  cp -- "$_MK_HOME_TRANSFORM_CONTENT" "$out_path"
  rm -f -- "$_MK_HOME_TRANSFORM_CONTENT"
}

home::dry_run::_show_diff() {
  local tmp_out="$1"
  if input::is_interactive >/dev/null; then
    home::dry_run::_show_interactive_diff "$tmp_out"
  else
    home::dry_run::_show_plain_diff "$tmp_out"
  fi
}

home::dry_run::_show_interactive_diff() {
  local tmp_out="$1"
  local diff_file
  diff_file=$(mktemp)
  home::dry_run::_generate_diff "$tmp_out" > "$diff_file"
  if [ ! -s "$diff_file" ]; then
    rm -f -- "$diff_file"
    logging::info "No changes to home files."
    return 0
  fi
  home::dry_run::_page_diff "$diff_file"
  rm -f -- "$diff_file"
}

home::dry_run::_generate_diff() {
  local tmp_out="$1"
  local out_path rel_path dest_path
  while IFS= read -r out_path; do
    rel_path="${out_path#"$tmp_out"/}"
    # The preview mirrors the absolute destination with the leading slash
    # stripped; re-add it to recover the real path.
    dest_path="/$rel_path"
    if [ ! -f "$dest_path" ]; then
      git diff --no-index --color=always /dev/null "$out_path" 2>/dev/null || true
    elif ! diff -q "$out_path" "$dest_path" >/dev/null 2>&1; then
      git diff --no-index --color=always "$dest_path" "$out_path" 2>/dev/null || true
    fi
  done < <(find "$tmp_out" -type f | sort)
}

home::dry_run::_page_diff() {
  local diff_file="$1"
  logging::info "  Unified diff format. In the pager: arrows/j/k scroll · / searches · q exits and continues."
  read -r -s -n 1 -p $'\n[machinekit] Press any key to open diff...' <"${MACHINEKIT_TTY:-/dev/tty}"
  printf '\n' >&2
  less -R "$diff_file"
}

home::dry_run::_show_plain_diff() {
  local tmp_out="$1"
  local has_changes=0 out_path rel_path dest_path
  while IFS= read -r out_path; do
    rel_path="${out_path#"$tmp_out"/}"
    # The preview mirrors the absolute destination with the leading slash
    # stripped; re-add it to recover the real path.
    dest_path="/$rel_path"
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
