#!/usr/bin/env bash
# zsh module — installs zsh and ships framework-level zsh dotfiles.
# env.zsh ends with a source loop over ~/.config/machinekit/env.zsh.d/*.zsh
# so any module can contribute a fragment via its own templates/ dir.

zsh::install() {
  logging::step "zsh install"
  brew::install_formula zsh
}
