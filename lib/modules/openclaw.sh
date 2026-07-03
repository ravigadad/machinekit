#!/usr/bin/env bash
# openclaw — installs the OpenClaw persistent-assistant CLI via the official
# installer.
#
# Like codex, cross-platform (macOS + Linux) and self-updating, so machinekit
# installs it from the vendor installer rather than pinning a brew package the
# self-updater would fight, and skips re-running once it's present. The installer
# reuses a compliant Node already on PATH (else bundles its own), so it runs
# through tool_version_manager::exec: when a version manager is active that puts
# node@latest on PATH for the installer to reuse; otherwise the installer
# self-provisions. Onboarding (the gateway/agent setup openclaw walks you through
# on first run) is an outside-world step machinekit deliberately leaves to you.

# Soft order after the version manager so mise is installed before the installer
# runs and can put node@latest on PATH — never required (the passthrough in
# tool_version_manager::exec covers the no-manager case).
openclaw::after() { printf 'tool_version_manager\n'; }

openclaw::install() {
  logging::step "openclaw install"
  if input::command_exists openclaw; then
    logging::debug "openclaw: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install OpenClaw via the official installer (openclaw.ai/install.sh)"
    return 0
  fi
  openclaw::_run_installer
  logging::success "openclaw: installed."
  logging::info "openclaw: run 'openclaw' to finish onboarding — machinekit does not handle it."
}

# install.sh (not install-cli.sh) so a compliant Node on PATH is reused rather
# than always bundling one; --install-method git tracks the repo for self-updates.
openclaw::_run_installer() {
  tool_version_manager::exec node@latest \
    bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --install-method git'
}
