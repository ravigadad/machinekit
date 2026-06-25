#!/usr/bin/env bash
# agents_config_harnesses::codex — projects the canonical agents config dir into
# Codex by symlinking its global instructions file (~/.codex/AGENTS.md) to the
# dir's AGENTS.md. Codex reads skills from the shared dir natively, so there is
# nothing to project for them. Sourced by agents_config_harnesses.sh, whose shared
# helpers carry the symlink mechanics; this submodule only supplies the path.

# Codex must be installed for the projection to matter; the resolver installs the
# codex module before this harness projects.
agents_config_harnesses::codex::requires() {
  printf 'codex\n'
}

agents_config_harnesses::codex::project() {
  agents_config_harnesses::_ensure_agents_md_link \
    "$(agents_config_harnesses::codex::_agents_md_link_path)" "$1"
}

agents_config_harnesses::codex::projection_present() {
  agents_config_harnesses::_agents_md_link_present \
    "$(agents_config_harnesses::codex::_agents_md_link_path)" "$1"
}

agents_config_harnesses::codex::_agents_md_link_path() {
  printf '%s/.codex/AGENTS.md\n' "$HOME"
}
