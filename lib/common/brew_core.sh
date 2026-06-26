#!/usr/bin/env bash
# brew_core — the Homebrew primitives shared by both brew layers: lib/bootstrap/brew.sh
# (the pure-3.2 island) and lib/machinekit/brew.sh (the modern module). Opinion-free:
# no logging and no interactivity policy (the caller passes that in), so the modern
# layer can source it without dragging in the bootstrap island's minimal helpers.
# Pure-3.2; keep it 3.2-safe forever.
[ -n "${_MK_BREW_CORE_LOADED:-}" ] && return 0
_MK_BREW_CORE_LOADED=1

# Put brew on PATH from whichever standard prefix has it.
brew_core::setup_path() {
  if   [ -x /opt/homebrew/bin/brew ];              then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ];                 then eval "$(/usr/local/bin/brew shellenv)"
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
}

# Run Homebrew's official installer. $1 non-empty => non-interactive (NONINTERACTIVE
# suppresses the installer's prompts); the caller owns the interactivity decision.
brew_core::run_official_installer() {
  if [ -n "${1:-}" ]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
}
