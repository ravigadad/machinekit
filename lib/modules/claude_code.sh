#!/usr/bin/env bash
# claude_code — installs the Claude Code CLI via Anthropic's official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. First-run auth opens a
# browser and signs you in as yourself — an outside-world, interactive step
# machinekit deliberately leaves to you (hence the postflight instruction, not an
# automated login).

claude_code::install() {
  logging::step "claude_code install"
  if input::command_exists claude; then
    logging::debug "claude_code: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install Claude Code via the official installer (claude.ai/install.sh)"
    return 0
  fi
  claude_code::_run_installer
  context::set "claude_code.installed" true
  logging::success "claude_code: installed."
}

# postflight: first-run auth (browser sign-in) is a deliberate hand-off. Surfaced
# only when the CLI was installed this run — there's no reliable signed-in probe,
# so a fresh install stands in for "not set up yet"; an already-present CLI stays
# quiet.
claude_code::postflight_instructions() {
  [ "$(context::get "claude_code.installed" --default false)" = "true" ] || return 0
  printf "Run 'claude' and sign in to finish setup — machinekit does not handle auth.\n"
}

claude_code::_run_installer() {
  curl -fsSL https://claude.ai/install.sh | bash
}
