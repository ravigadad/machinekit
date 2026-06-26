#!/usr/bin/env bash
# bootstrap::brew — the bootstrap island's Homebrew orchestration: ensure Homebrew is
# present, install Homebrew's bash, and locate it. Runs before any modern lib and
# before input::detect_mode, so it carries its own minimal log/fail/have/interactive
# helpers (never logging::/input::/lifecycle::) and gets the genuinely shared
# primitives from lib/common/brew_core.sh. Pure-3.2; keep it 3.2-safe forever.
[ -n "${_MK_BOOTSTRAP_BREW_LOADED:-}" ] && return 0
_MK_BOOTSTRAP_BREW_LOADED=1

# shellcheck source=../common/brew_core.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/brew_core.sh"

bootstrap::brew::_log()  { printf 'machinekit: %s\n' "$1" >&2; }
bootstrap::brew::_fail() { printf 'machinekit: %s\n' "$1" >&2; exit 1; }
bootstrap::brew::_have() { command -v "$1" >/dev/null 2>&1; }

# Fail unless a command is present. Shared by ensure (post-install check) and
# install_bash (precondition).
bootstrap::brew::_require() {
  bootstrap::brew::_have "$1" || bootstrap::brew::_fail "$2"
}

# We run before input::detect_mode, so interactivity comes off the TTY directly.
bootstrap::brew::_interactive() { [ -t 0 ]; }

# Ensure Homebrew is installed and on PATH, installing it via the official installer
# if absent.
bootstrap::brew::ensure() {
  brew_core::setup_path
  bootstrap::brew::_have brew && return 0
  bootstrap::brew::_log "installing Homebrew..."
  bootstrap::brew::_run_installer
  brew_core::setup_path
  bootstrap::brew::_require brew "Homebrew installed but 'brew' not found on any standard prefix."
}

# Drive the shared installer with this island's TTY-based interactivity decision.
# The installer's chatter is logging — to stderr, so it can't pollute the resolved
# bash path the dispatcher captures off this island's stdout.
bootstrap::brew::_run_installer() {
  if bootstrap::brew::_interactive; then
    brew_core::run_official_installer "" >&2
  else
    brew_core::run_official_installer 1 >&2
  fi
}

# Install the bash formula (brew no-ops if already present). HOMEBREW_NO_ASK
# suppresses Homebrew's install-plan prompt when we have no TTY to answer it.
# brew's summary/caveats are logging — to stderr, so they can't pollute the
# resolved bash path the dispatcher captures off this island's stdout.
bootstrap::brew::install_bash() {
  bootstrap::brew::_require brew "Homebrew is not installed"
  if bootstrap::brew::_interactive; then
    brew install bash >&2
  else
    HOMEBREW_NO_ASK=1 brew install bash >&2
  fi
}

# Absolute path to brew's bash.
bootstrap::brew::bash_path() {
  printf '%s/bin/bash\n' "$(brew --prefix)"
}
