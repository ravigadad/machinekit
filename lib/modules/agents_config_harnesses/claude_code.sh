#!/usr/bin/env bash
# agents_config_harnesses::claude_code — projects the canonical agents config dir
# into Claude Code. Sourced by agents_config_harnesses.sh, which dispatches the
# contract every harness submodule provides:
#   requires            — the agent tool module this harness needs installed
#   project DIR         — wire Claude Code to DIR (idempotent)
#   projection_present  — whether both bindings are already in place
#
# Two set-once bindings (validated by spike): a directory symlink
# ~/.claude/skills → DIR/skills (the skills surface as load-when-relevant,
# description-gated) and an `@DIR/AGENTS.md` import in ~/.claude/CLAUDE.md (the
# top-level instructions load every session). Both stay live as the synced dir
# changes — no re-run needed.

# Claude Code must be installed for the projection to matter; the resolver
# installs claude_code before this harness projects.
agents_config_harnesses::claude_code::requires() {
  printf 'claude_code\n'
}

# Both bindings already in place → nothing to do.
agents_config_harnesses::claude_code::projection_present() {
  local agents_config_dir="$1"
  agents_config_harnesses::claude_code::_skills_link_present "$agents_config_dir" \
    && agents_config_harnesses::claude_code::_agents_md_import_present "$agents_config_dir"
}

# Each binding is independently idempotent, so projecting a partial state heals
# it. Dry-run is gated in the parent (this is not called then).
agents_config_harnesses::claude_code::project() {
  local agents_config_dir="$1"
  agents_config_harnesses::claude_code::_ensure_skills_link "$agents_config_dir"
  agents_config_harnesses::claude_code::_ensure_agents_md_import "$agents_config_dir"
}

# Own ~/.claude/skills as a symlink to the skills dir, via the shared link
# primitive (a directory symlink is a link like any other).
agents_config_harnesses::claude_code::_ensure_skills_link() {
  agents_config_harnesses::_ensure_link \
    "$(agents_config_harnesses::claude_code::_skills_link_path)" \
    "$(agents_config_harnesses::claude_code::_skills_dir "$1")"
}

# Ensure ~/.claude/CLAUDE.md imports the AGENTS.md instructions file. Append
# under a managed header if absent (creating the file if needed). No-op if
# already present.
agents_config_harnesses::claude_code::_ensure_agents_md_import() {
  local agents_config_dir="$1" claude_md_path agents_md_import_line
  claude_md_path="$(agents_config_harnesses::claude_code::_claude_md_path)"
  agents_config_harnesses::claude_code::_agents_md_import_present "$agents_config_dir" && return 0
  agents_md_import_line="$(agents_config_harnesses::claude_code::_agents_md_import_line "$agents_config_dir")"
  mkdir -p "$(dirname "$claude_md_path")"
  printf '\n## Agent instructions (projected from %s)\n\n%s\n' "$agents_config_dir" "$agents_md_import_line" >> "$claude_md_path"
}

agents_config_harnesses::claude_code::_skills_link_present() {
  agents_config_harnesses::_link_present \
    "$(agents_config_harnesses::claude_code::_skills_link_path)" \
    "$(agents_config_harnesses::claude_code::_skills_dir "$1")"
}

agents_config_harnesses::claude_code::_agents_md_import_present() {
  local agents_config_dir="$1" claude_md_path agents_md_import_line
  claude_md_path="$(agents_config_harnesses::claude_code::_claude_md_path)"
  [ -f "$claude_md_path" ] || return 1
  agents_md_import_line="$(agents_config_harnesses::claude_code::_agents_md_import_line "$agents_config_dir")"
  grep -qF "$agents_md_import_line" "$claude_md_path"
}

agents_config_harnesses::claude_code::_skills_link_path() {
  printf '%s/.claude/skills\n' "$HOME"
}

agents_config_harnesses::claude_code::_claude_md_path() {
  printf '%s/.claude/CLAUDE.md\n' "$HOME"
}

agents_config_harnesses::claude_code::_skills_dir() {
  local agents_config_dir="$1"
  printf '%s/skills\n' "$agents_config_dir"
}

agents_config_harnesses::claude_code::_agents_md_import_line() {
  local agents_config_dir="$1"
  printf '@%s/AGENTS.md\n' "$agents_config_dir"
}
