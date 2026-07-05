#!/usr/bin/env bash
# Home dry-run — when running dry-run, generates and presents a diff.
[ -n "${_MK_HOME_DRY_RUN_LOADED:-}" ] && return 0
_MK_HOME_DRY_RUN_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../home.sh"

home::dry_run::show_diff() {
  logging::step "home dry-run: diff against $HOME"
  local tmp_out
  tmp_out=$(mktemp -d)

  home::_each_planned_file home::dry_run::_render_to_outdir "$tmp_out"

  home::dry_run::_show_diff "$tmp_out"

  rm -rf -- "$tmp_out"
}

# Called by home::_each_planned_file with (out_dir, then the record fields).
# Takes the same record apply does; $3 src_rel and $6 private are received for
# parity but not surfaced in the preview yet.
home::dry_run::_render_to_outdir() {
  # shellcheck disable=SC2034  # src_rel, private: received for parity, unused here
  local out_dir="$1" src="$2" src_rel="$3" dest="$4" key="$5" private="$6" suppressed="$7"; shift 7
  if [ "$suppressed" = "true" ]; then
    logging::debug "home dry-run: skipping $key (suppressed by .mkignore)"
    return 0
  fi
  # Mirror the absolute destination under the preview dir (leading slash
  # stripped); _generate_diff re-roots back to the real path by re-adding it.
  local out_path="$out_dir/${dest#/}"
  mkdir -p "$(dirname "$out_path")"

  local content
  content=${ home::transforms::execute "$src" "$@"; }
  cp -- "$content" "$out_path"
  rm -f -- "$content"
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
