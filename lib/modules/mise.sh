#!/usr/bin/env bash
# mise module — installs runtimes pinned in ~/.config/mise/config.toml
# (or any discoverable .tool-versions). No-op when nothing is pinned.

mise::install() {
  logging::step "mise install"
  brew::install_formula mise
  if input::is_dry_run; then
    logging::dry_run "would run: mise install"
    return 0
  fi
  mise install || logging::warn "mise install reported an error; continuing."
  logging::success "mise install complete."
}
