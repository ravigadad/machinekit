# starship — cross-shell prompt.
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/config.toml"
  eval "$(starship init zsh)"
fi
