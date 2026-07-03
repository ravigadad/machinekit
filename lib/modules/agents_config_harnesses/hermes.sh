#!/usr/bin/env bash
# agents_config_harnesses::hermes — projects the canonical agents config dir into
# Hermes. Hermes reads a single identity file, ~/.hermes/SOUL.md (it folds
# identity into SOUL and reads nothing else), so this symlinks that path to the
# dir's SOUL.md. Sourced by agents_config_harnesses.sh; the shared _ensure_link
# helper carries the symlink mechanics (and creates ~/.hermes as needed, the way
# codex's projection creates ~/.codex).
#
# Source-gated: skip until SOUL.md is authored in the agents config dir, so no
# dangling link is created before the content exists.

agents_config_harnesses::hermes::requires() {
  printf 'hermes\n'
}

agents_config_harnesses::hermes::project() {
  local source
  source="$(agents_config_harnesses::hermes::_soul_source "$1")"
  [ -e "$source" ] || return 0
  agents_config_harnesses::_ensure_link \
    "$(agents_config_harnesses::hermes::_soul_link_path)" "$source"
}

agents_config_harnesses::hermes::projection_present() {
  local source
  source="$(agents_config_harnesses::hermes::_soul_source "$1")"
  [ -e "$source" ] || return 0
  agents_config_harnesses::_link_present \
    "$(agents_config_harnesses::hermes::_soul_link_path)" "$source"
}

agents_config_harnesses::hermes::_soul_link_path() {
  printf '%s/.hermes/SOUL.md\n' "$HOME"
}

agents_config_harnesses::hermes::_soul_source() {
  printf '%s/SOUL.md\n' "$1"
}
