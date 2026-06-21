#!/usr/bin/env bash
# Maintain a delimited, machinekit-owned block of lines inside a file. The block
# is reconciled from config on every run — its content is whatever the caller
# pipes in (one line per pattern, empty input = empty delimiters) — while
# everything outside the markers is the user's and stays untouched. Removing the
# block but keeping the file just gets it restored next run; the only way to opt
# out is for the caller not to call this.
#
# Shared by modules that manage an ignore-style file (syncthing's .stignore,
# git_backup's .gitignore); the marker comment prefix differs per file type
# (`#`, `//`), so it's a parameter.
[ -n "${_MK_MANAGED_BLOCK_LOADED:-}" ] && return 0
_MK_MANAGED_BLOCK_LOADED=1

_MK_MANAGED_BLOCK_MARKER_PHRASE="machinekit managed block"
_MK_MANAGED_BLOCK_BEGIN_MARKER=">>> $_MK_MANAGED_BLOCK_MARKER_PHRASE >>>"
_MK_MANAGED_BLOCK_END_MARKER="<<< $_MK_MANAGED_BLOCK_MARKER_PHRASE <<<"

# managed_block::ensure FILE COMMENT_PREFIX   (block body on stdin, one line each)
# Insert or replace machinekit's block in FILE. A well-formed block (the first
# begin marker through the first following end marker) is replaced in place,
# preserving its position; if none exists the block is appended. Stray marker
# lines outside a matched pair are dropped, never the content around them — so a
# half-deleted block can never eat the user's file.
managed_block::ensure() {
  local file="$1" comment_prefix="$2"
  local begin="$comment_prefix $_MK_MANAGED_BLOCK_BEGIN_MARKER"
  local end="$comment_prefix $_MK_MANAGED_BLOCK_END_MARKER"
  local body line number begin_line=0 end_line=0 has_region=0 tmp
  body=$(cat)

  if [ -f "$file" ]; then
    number=0
    while IFS= read -r line || [ -n "$line" ]; do
      number=$((number + 1))
      if [ "$begin_line" -eq 0 ] && [ "$line" = "$begin" ]; then
        begin_line=$number
      elif [ "$begin_line" -ne 0 ] && [ "$end_line" -eq 0 ] && [ "$line" = "$end" ]; then
        end_line=$number
      fi
    done < "$file"
  fi
  [ "$begin_line" -ne 0 ] && [ "$end_line" -ne 0 ] && has_region=1

  tmp=$(mktemp "${TMPDIR:-/tmp}/machinekit-managed-block.XXXXXX")
  if [ -f "$file" ]; then
    number=0
    while IFS= read -r line || [ -n "$line" ]; do
      number=$((number + 1))
      if [ "$has_region" -eq 1 ] && [ "$number" -ge "$begin_line" ] && [ "$number" -le "$end_line" ]; then
        [ "$number" -eq "$begin_line" ] && managed_block::_emit "$begin" "$body" "$end" >> "$tmp"
        continue
      fi
      if [ "$line" = "$begin" ] || [ "$line" = "$end" ]; then
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$file"
  fi
  [ "$has_region" -eq 0 ] && managed_block::_emit "$begin" "$body" "$end" >> "$tmp"

  mv "$tmp" "$file"
}

managed_block::_emit() {
  local begin="$1" body="$2" end="$3"
  printf '%s\n' "$begin"
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  fi
  printf '%s\n' "$end"
}
