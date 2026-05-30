# ~/.config/machinekit/env.zsh — managed by machinekit.
# To override or extend, use ~/.zshrc.local (not managed by machinekit).

# Homebrew puts this in ~/.zprofile (login shells only), so non-login shells
# (VS Code terminal, ssh, subshells) won't have brew on PATH without it here.
if   [ -x /opt/homebrew/bin/brew ];              then eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ];                 then eval "$(/usr/local/bin/brew shellenv)"
elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# User-local binaries.
export PATH="${HOME}/.local/bin:${PATH}"

# History
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS

# Completion
autoload -Uz compinit && compinit

# Module-contributed shell fragments.
if [ -d "${HOME}/.config/machinekit/env.zsh.d" ]; then
  for _mk_env_fragment in "${HOME}/.config/machinekit/env.zsh.d/"*.zsh; do
    [ -f "$_mk_env_fragment" ] && source "$_mk_env_fragment"
  done
  unset _mk_env_fragment
fi
