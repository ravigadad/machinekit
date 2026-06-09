#!/usr/bin/env bash
# mise module — installs the mise runtime version manager.
# Runtime installation (mise install) happens in ::post_apply, after home::sync
# places ~/.config/mise/config.toml.

mise::provides() { printf 'tool_version_manager\n'; }

mise::requires() { printf 'zsh\n'; }

mise::install() {
  logging::step "mise install"
  brew::install_formula mise
}

mise::post_apply() {
  logging::step "mise: install runtimes"
  if input::is_dry_run; then
    logging::dry_run "would run: mise install"
    return 0
  fi
  mise install || logging::warn "mise install reported an error; continuing."
  logging::success "mise install complete."
}
