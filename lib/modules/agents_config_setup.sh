#!/usr/bin/env bash
# agents_config_setup — ensures the canonical agents config dir is on this
# machine. When the dir is absent, it seeds it from a configured source (a git
# repo, a git-inited dir, or a plain dir to copy) via the source-agnostic fetch::
# core — the same machinery blueprints uses, reading source + an optional
# protocol override from [module.agents_config_setup] instead of CLI/env.
#
# Owns the canonical `dir` key; the sibling
# agents_config_harnesses reads the same key to know what to project. No
# dependency between them — same agents_config_ category, like
# hindsight_server/hindsight_integration.
#
# Seeding only ever fills an absent/empty dir; an already-populated dir is left
# untouched (idempotent, never clobbered), so cloning is a local set-up step with
# no consent gate — like blueprints' own fetch. After a git seed the .git is
# stripped, so the machine carries plain content, not a repo: git_backup rebuilds
# its own repo from the remote on the backup machine, and Syncthing must not
# replicate a live .git across the fleet.

# Fail early when there's nothing on disk and no way to seed it, rather than at
# install time. A dir that's already present needs no source.
agents_config_setup::preflight() {
  local dir source override
  dir=$(agents_config_setup::dir)
  if ! agents_config_setup::_present "$dir"; then
    source=$(agents_config_setup::_source)
    [ -n "$source" ] || lifecycle::fail \
      "agents_config_setup: $dir is absent and no source is configured to seed it. Set [module.agents_config_setup].source."
    # Validate the source/protocol now, cleanly, rather than mid-install: an unknown
    # source_protocol or a cp/URL mismatch fails here via resolve_protocol's own
    # lifecycle::fail (called directly, so it isn't swallowed in a $() subshell).
    override=$(agents_config_setup::_source_protocol)
    fetch::resolve_protocol "$source" "$override" >/dev/null
  fi
}

agents_config_setup::install() {
  logging::step "agents_config_setup install"
  local dir source override protocol
  dir=$(agents_config_setup::dir)
  if agents_config_setup::_present "$dir"; then
    # Idempotent skip: quiet on a normal run, but a dry run must still report the
    # no-op rather than going silent.
    if input::is_dry_run; then
      logging::dry_run "agents config dir ($dir) already present; would seed nothing"
    else
      logging::debug "agents_config_setup: $dir already present; nothing to seed"
    fi
  elif input::is_dry_run; then
    logging::dry_run "would seed the agents config dir ($dir) from $(agents_config_setup::_source), then strip its .git (plain content; git_backup owns any repo)"
  else
    source=$(agents_config_setup::_source)
    override=$(agents_config_setup::_source_protocol)
    protocol=$(fetch::resolve_protocol "$source" "$override")
    logging::info "Seeding agents config dir ($dir) from $source"
    # shallow: the .git is stripped right after, so history is pure waste to fetch.
    fetch::into "$source" "$dir" "$protocol" shallow
    agents_config_setup::_strip_git "$dir"
  fi
}

# Drop the seeded dir's .git so the machine holds plain content, not a repo. Done
# uniformly on every machine, with no "am I the committer" check: the backup
# machine's git_backup reconstructs its own repo from the remote, so this module
# needs no knowledge of who backs up. A cp/plain-dir seed has no .git, so the rm is
# then a no-op. Also keeps a live .git off the mesh — git, not Syncthing, owns
# version-control state.
agents_config_setup::_strip_git() {
  local dir="$1"
  rm -rf "$dir/.git"
  logging::debug "agents_config_setup: stripped $dir/.git (plain content dir)"
}

# The canonical agents config dir — the shared key this module owns. Public so
# the sibling agents_config_harnesses reads it through one accessor instead of
# duplicating the key and default. A pure config read with a default, so a caller
# resolves it whether or not this module is activated.
agents_config_setup::dir() {
  config::get "module.agents_config_setup.dir" --default "$HOME/.agents"
}

# Where to seed the dir from when it's absent (URL or local path). Empty unless
# configured — preflight requires it only when there's nothing on disk yet.
agents_config_setup::_source() {
  config::get "module.agents_config_setup.source" --default ""
}

# Optional protocol override for the source (git or cp); empty means fetch::
# sniffs it from the source.
agents_config_setup::_source_protocol() {
  config::get "module.agents_config_setup.source_protocol" --default ""
}

# Present = a non-empty directory exists. An empty dir is treated as absent so
# fetch:: (git clone, which refuses a non-empty dir) can seed into it.
agents_config_setup::_present() {
  [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}
