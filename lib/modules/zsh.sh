#!/usr/bin/env bash
# zsh module — installs zsh and ships framework-level zsh dotfiles.
# env.zsh ends with a source loop over the env.zsh.d/ dir in machinekit's config
# dir (${XDG_CONFIG_HOME:-$HOME/.config}/machinekit), so any module can
# contribute a fragment via its own templates/ dir.

zsh::install() {
  logging::step "zsh install"
  brew::install_formula zsh
}
