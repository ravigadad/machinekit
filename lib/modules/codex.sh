#!/usr/bin/env bash
# codex — installs the OpenAI Codex CLI via the official installer.
#
# Cross-platform (macOS + Linux) and self-updating, so machinekit installs it
# from the vendor installer rather than pinning a brew package the self-updater
# would fight, and skips re-running once it's present. First-run auth signs you in
# with ChatGPT — an outside-world, interactive step machinekit deliberately leaves
# to you (hence the postflight instruction, not an automated login).

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
  context::set "codex.installed" true
  logging::success "codex: installed."
}

# postflight: first-run auth (ChatGPT sign-in) is a deliberate hand-off. Surfaced
# only when the CLI was installed this run — there's no reliable signed-in probe,
# so a fresh install stands in for "not set up yet"; an already-present CLI stays
# quiet.
codex::postflight_instructions() {
  [ "$(context::get "codex.installed" --default false)" = "true" ] || return 0
  printf "Run 'codex' and sign in to finish setup — machinekit does not handle auth.\n"
}

codex::_run_installer() {
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
}
