#!/usr/bin/env bash
# agents_config_harnesses::opencode — projects the canonical agents config dir into
# opencode by symlinking its global instructions file (~/.config/opencode/AGENTS.md)
# to the dir's AGENTS.md. opencode reads skills from the shared dir natively, so
# there is nothing to project for them. Sourced by agents_config_harnesses.sh, whose
# shared helpers carry the symlink mechanics; this submodule only supplies the path.

# opencode must be installed for the projection to matter; the resolver installs the
# opencode module before this harness projects.
agents_config_harnesses::opencode::requires() {
  printf 'opencode\n'
}

agents_config_harnesses::opencode::project() {
  agents_config_harnesses::_ensure_agents_md_link \
    "$(agents_config_harnesses::opencode::_agents_md_link_path)" "$1"
}

agents_config_harnesses::opencode::projection_present() {
  agents_config_harnesses::_agents_md_link_present \
    "$(agents_config_harnesses::opencode::_agents_md_link_path)" "$1"
}

agents_config_harnesses::opencode::_agents_md_link_path() {
  printf '%s/.config/opencode/AGENTS.md\n' "$HOME"
}
