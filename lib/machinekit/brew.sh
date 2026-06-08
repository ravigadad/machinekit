#!/usr/bin/env bash
# Core Homebrew helpers: bootstrap the package manager and install formulae.
# Sourced, not executed.
[ -n "${_MK_BREW_LOADED:-}" ] && return 0
_MK_BREW_LOADED=1

_MK_BREW_FORMULAE_CACHE=""
_MK_BREW_FORMULAE_CACHED=0

brew::bootstrap() {
  logging::step "Homebrew"
  brew::_setup_path
  if input::command_exists brew; then
    logging::success "Homebrew already installed at $(command -v brew)"
    return 0
  fi
  brew::_install
}

brew::install_formula() {
  local formula="$1"; shift
  local override_dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override-dry-run) override_dry_run=true ;;
      *) lifecycle::fail "brew::install_formula: unknown option: $1" ;;
    esac
    shift
  done
  input::command_exists brew || lifecycle::fail "Homebrew is not installed"
  local dry_run=false
  if [ "$override_dry_run" = false ] && input::is_dry_run; then dry_run=true; fi
  if brew::is_formula_installed "$formula"; then
    logging::debug "brew: $formula already installed"
  elif [ "$dry_run" = true ]; then
    logging::dry_run "would install: $formula"
  else
    logging::info "brew install $formula"
    brew install "$formula"
  fi
}

brew::is_formula_installed() {
  # Warm cache in the current shell so _MK_BREW_FORMULAE_CACHED propagates;
  # the subshell for command substitution would otherwise never update it.
  brew::_installed_formulae >/dev/null
  grep -qxF "$1" <<< "$(brew::_installed_formulae)"
}

brew::_setup_path() {
  if   [ -x /opt/homebrew/bin/brew ];              then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ];                 then eval "$(/usr/local/bin/brew shellenv)"
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
}

brew::_install() {
  logging::info "Installing Homebrew..."
  if ! input::is_interactive >/dev/null; then
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew::_setup_path
  input::command_exists brew || lifecycle::fail "Homebrew installed but 'brew' not found on any standard prefix."
  logging::success "Homebrew installed."
}

brew::_installed_formulae() {
  if [ "$_MK_BREW_FORMULAE_CACHED" != "1" ]; then
    input::command_exists brew || return 0
    _MK_BREW_FORMULAE_CACHE=$(brew list --formula 2>/dev/null || true)
    _MK_BREW_FORMULAE_CACHED=1
  fi
  printf '%s\n' "$_MK_BREW_FORMULAE_CACHE"
}
