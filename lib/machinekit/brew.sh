#!/usr/bin/env bash
# Core Homebrew helpers: bootstrap the package manager and install formulae/casks.
# Sourced, not executed.
[ -n "${_MK_BREW_LOADED:-}" ] && return 0
_MK_BREW_LOADED=1

# One installed-list cache per kind (formula|cask).
_MK_BREW_FORMULA_CACHE=""
_MK_BREW_FORMULA_CACHED=0
_MK_BREW_CASK_CACHE=""
_MK_BREW_CASK_CACHED=0

brew::bootstrap() {
  logging::step "Homebrew"
  brew::_setup_path
  if input::command_exists brew; then
    logging::success "Homebrew already installed at $(command -v brew)"
    return 0
  fi
  brew::_install_homebrew
}

# Formulae and casks install identically apart from the `--cask` flag and which
# installed-list they check against, so both share one implementation.
brew::install_formula() { brew::_install_pkg formula "$@"; }
brew::install_cask()    { brew::_install_pkg cask "$@"; }

# brew::_install_pkg KIND NAME [--override-dry-run]
brew::_install_pkg() {
  local kind="$1" name="$2"; shift 2
  local override_dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override-dry-run) override_dry_run=true ;;
      *) lifecycle::fail "brew::install_${kind}: unknown option: $1" ;;
    esac
    shift
  done
  input::command_exists brew || lifecycle::fail "Homebrew is not installed"
  local dry_run=false
  if [ "$override_dry_run" = false ] && input::is_dry_run; then dry_run=true; fi
  if brew::_is_installed "$kind" "$name"; then
    logging::debug "brew: $name already installed"
  elif [ "$dry_run" = true ]; then
    logging::dry_run "would install ($kind): $name"
  elif [ "$kind" = cask ]; then
    logging::info "brew install --cask $name"
    brew install --cask "$name"
  else
    logging::info "brew install $name"
    brew install "$name"
  fi
}

# brew::_is_installed KIND NAME — is the named formula/cask already present?
brew::_is_installed() {
  local kind="$1" name="$2"
  # Warm cache in the current shell so the *_CACHED flag propagates; the
  # subshell for command substitution would otherwise never update it.
  brew::_installed "$kind" >/dev/null
  grep -qxF "$name" <<< "$(brew::_installed "$kind")"
}

brew::_setup_path() {
  if   [ -x /opt/homebrew/bin/brew ];              then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ];                 then eval "$(/usr/local/bin/brew shellenv)"
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
}

# Absolute path to the brew binary. Callers running brew under sudo need this:
# sudo's secure_path drops the Homebrew prefix, so a bare `brew` won't resolve.
brew::_bin() {
  command -v brew
}

brew::_install_homebrew() {
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

# brew::_installed KIND — cached output of `brew list --KIND`, fetched once per
# kind per run. Indirect var names keep the per-kind caches without duplication.
brew::_installed() {
  local kind="$1" cache_var cached_var
  case "$kind" in
    formula) cache_var=_MK_BREW_FORMULA_CACHE; cached_var=_MK_BREW_FORMULA_CACHED ;;
    cask)    cache_var=_MK_BREW_CASK_CACHE;    cached_var=_MK_BREW_CASK_CACHED ;;
    *) lifecycle::fail "brew::_installed: unknown kind: $kind" ;;
  esac
  if [ "${!cached_var}" != "1" ]; then
    input::command_exists brew || return 0
    printf -v "$cache_var" '%s' "$(brew list --"$kind" 2>/dev/null || true)"
    printf -v "$cached_var" '%s' 1
  fi
  printf '%s\n' "${!cache_var}"
}
