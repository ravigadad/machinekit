#!/usr/bin/env bash
# opencode — installs the opencode CLI via the official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. opencode is provider-
# agnostic: first run is where you configure a model provider and its credentials
# — an outside-world step machinekit deliberately leaves to you (hence the
# postflight instruction, not automated config).

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
  context::set "opencode.installed" true
  logging::success "opencode: installed."
}

# postflight: first run is where provider config + credentials are set — a
# deliberate hand-off. Surfaced only when the CLI was installed this run: there's
# no reliable configured probe, so a fresh install stands in for "not set up
# yet"; an already-present CLI stays quiet.
opencode::postflight_instructions() {
  [ "$(context::get "opencode.installed" --default false)" = "true" ] || return 0
  printf "Run 'opencode' to finish setup — machinekit does not handle provider config or auth.\n"
}

opencode::_run_installer() {
  curl -fsSL https://opencode.ai/install | bash
}
