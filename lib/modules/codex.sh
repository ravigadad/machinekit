#!/usr/bin/env bash
# codex — installs the OpenAI Codex CLI via the official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. First-run auth signs you in
# with ChatGPT — an outside-world, interactive step machinekit deliberately leaves
# to you (hence the post-install reminder, not an automated login).

codex::install() {
  logging::step "codex install"
  if input::command_exists codex; then
    logging::debug "codex: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install Codex CLI via the official installer (chatgpt.com/codex/install.sh)"
    return 0
  fi
  codex::_run_installer
  logging::success "codex: installed."
  logging::info "codex: run 'codex' and sign in to finish setup — machinekit does not handle auth."
}

codex::_run_installer() {
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
}
