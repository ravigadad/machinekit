#!/usr/bin/env bash
# starship module — installs the starship cross-shell prompt.
# Ships its config to ~/.config/starship/config.toml (starship has no native XDG
# support but honors STARSHIP_CONFIG) plus an env.zsh.d snippet that points
# STARSHIP_CONFIG at it and initializes the prompt for zsh.

starship::requires() { printf 'zsh\n'; }

starship::install() {
  logging::step "starship install"
  brew::install_formula starship
}

starship::postflight_info() {
  printf 'starship prompt installed; config at ~/.config/starship/config.toml.\n'
}

starship::postflight_instructions() {
  printf 'For prompt glyphs, install a Nerd Font and enable it in your terminal: https://www.nerdfonts.com\n'
  printf "Personalize it — presets: 'starship preset -l' (https://starship.rs/presets); full config: https://starship.rs/config\n"
}
