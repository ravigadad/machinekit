#!/usr/bin/env bash
# claude_code — installs the Claude Code CLI via Anthropic's official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. First-run auth opens a
# browser and signs you in as yourself — an outside-world, interactive step
# machinekit deliberately leaves to you (hence the post-install reminder, not an
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
  logging::success "claude_code: installed."
  logging::info "claude_code: run 'claude' and sign in to finish setup — machinekit does not handle auth."
}

claude_code::_run_installer() {
  curl -fsSL https://claude.ai/install.sh | bash
}
