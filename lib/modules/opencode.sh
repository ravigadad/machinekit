#!/usr/bin/env bash
# opencode — installs the opencode CLI via the official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. opencode is provider-
# agnostic: first run is where you configure a model provider and its credentials
# — an outside-world step machinekit deliberately leaves to you (hence the
# post-install reminder, not automated config).

opencode::install() {
  logging::step "opencode install"
  if input::command_exists opencode; then
    logging::debug "opencode: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install opencode via the official installer (opencode.ai/install)"
    return 0
  fi
  opencode::_run_installer
  logging::success "opencode: installed."
  logging::info "opencode: run 'opencode' to finish setup — machinekit does not handle provider config or auth."
}

opencode::_run_installer() {
  curl -fsSL https://opencode.ai/install | bash
}
