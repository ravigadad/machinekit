#!/usr/bin/env bash
# zsh module — ships framework-level zsh dotfiles (dot_zshrc,
# dot_config/machinekit/env.zsh). env.zsh ends with a source loop over
# ~/.config/machinekit/env.zsh.d/*.zsh, so any module can contribute a
# zsh fragment by dropping a file in its own templates/ dir.

zsh::install() {
  :
}
