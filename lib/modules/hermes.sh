#!/usr/bin/env bash
# hermes — installs the Hermes persistent-assistant CLI via the official
# installer.
#
# Like openclaw, cross-platform and self-updating, so machinekit installs it from
# the vendor installer rather than a brew package, and skips re-running once it's
# present. The installer reuses a compliant Node on PATH — so it runs through
# tool_version_manager::exec node@latest — and otherwise self-provisions Node
# along with its Python venv, ripgrep, and ffmpeg. First-run setup is an
# outside-world step machinekit deliberately leaves to you.

# Soft order after the version manager so mise is installed before the installer
# runs and can put node@latest on PATH — never required (the passthrough in
# tool_version_manager::exec covers the no-manager case).
hermes::after() { printf 'tool_version_manager\n'; }

hermes::install() {
  logging::step "hermes install"
  if input::command_exists hermes; then
    logging::debug "hermes: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install Hermes via the official installer (hermes-agent.nousresearch.com/install.sh)"
    return 0
  fi
  hermes::_run_installer
  context::set "hermes.installed" true
  logging::success "hermes: installed."
}

# postflight: first-run setup is a deliberate hand-off. Surfaced only when the
# CLI was installed this run — there's no reliable configured probe, so a fresh
# install stands in for "not set up yet"; an already-present CLI stays quiet.
hermes::postflight_instructions() {
  [ "$(context::get "hermes.installed" --default false)" = "true" ] || return 0
  printf "Run 'hermes' to finish setup — machinekit does not handle it.\n"
}

hermes::_run_installer() {
  tool_version_manager::exec node@latest \
    bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
}
