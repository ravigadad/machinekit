#!/usr/bin/env bash
# agents_config_harnesses::openclaw — projects the canonical agents config dir
# into OpenClaw. OpenClaw reads its identity + instruction files (SOUL.md,
# IDENTITY.md, USER.md, AGENTS.md) and its skills from its workspace dir, so this
# symlinks each into the workspace, back to the like-named entry in the agents
# config dir. Sourced by agents_config_harnesses.sh; the shared _ensure_link
# helper carries the symlink mechanics.
#
# Only the default workspace (~/.openclaw/workspace) is projected into: OpenClaw's
# profile/per-agent workspaces exist to differentiate agents, so syncing one
# identity into all of them would defeat their purpose. Two present-gates keep the
# projection honest — skip entirely until the workspace exists (it is created by
# OpenClaw's own onboarding, which machinekit punts to the user), and skip any
# entry whose source isn't authored yet (SOUL/IDENTITY/USER may not exist), so no
# dangling links are ever created.

agents_config_harnesses::openclaw::requires() {
  printf 'openclaw\n'
}

agents_config_harnesses::openclaw::project() {
  local agents_config_dir="$1" workspace entry source
  workspace="$(agents_config_harnesses::openclaw::_workspace_dir)"
  while IFS= read -r entry; do
    source="$agents_config_dir/$entry"
    [ -e "$source" ] || continue
    agents_config_harnesses::_ensure_link "$workspace/$entry" "$source"
  done < <(agents_config_harnesses::openclaw::_projected_entries)
}

agents_config_harnesses::openclaw::projection_present() {
  local agents_config_dir="$1" workspace entry source
  workspace="$(agents_config_harnesses::openclaw::_workspace_dir)"
  [ -d "$workspace" ] || return 0
  while IFS= read -r entry; do
    source="$agents_config_dir/$entry"
    [ -e "$source" ] || continue
    agents_config_harnesses::_link_present "$workspace/$entry" "$source" || return 1
  done < <(agents_config_harnesses::openclaw::_projected_entries)
  return 0
}

agents_config_harnesses::openclaw::_workspace_dir() {
  printf '%s/.openclaw/workspace\n' "$HOME"
}

# The workspace entries that map to like-named items in the agents config dir.
# MEMORY.md and TOOLS.md are deliberately excluded — Hindsight owns memory, and
# tools are not part of the identity layer.
agents_config_harnesses::openclaw::_projected_entries() {
  printf '%s\n' SOUL.md IDENTITY.md USER.md AGENTS.md skills
}
