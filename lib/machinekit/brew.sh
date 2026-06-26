#!/usr/bin/env bash
# Core Homebrew helpers: bootstrap the package manager and install formulae/casks.
# Sourced, not executed.
[ -n "${_MK_BREW_LOADED:-}" ] && return 0
_MK_BREW_LOADED=1

# The path setup and the official-installer invocation are shared with the pure-3.2
# bootstrap island; both live in lib/common/brew_core.sh (opinion-free). This module
# adds the logging::/input::-aware orchestration on top.
# shellcheck source=../common/brew_core.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/brew_core.sh"

# One installed-list cache per kind (formula|cask).
_MK_BREW_FORMULA_CACHE=""
_MK_BREW_FORMULA_CACHED=0
_MK_BREW_CASK_CACHE=""
_MK_BREW_CASK_CACHED=0

brew::bootstrap() {
  logging::step "Homebrew"
  brew_core::setup_path
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
    brew::_run_install --cask "$name"
    brew::_invalidate_installed "$kind"
  else
    logging::info "brew install $name"
    brew::_run_install "$name"
    brew::_invalidate_installed "$kind"
  fi
}

# Runs `brew install` with the interactivity machinekit is running in, mirroring
# the Homebrew bootstrap's mode-matching. In non-interactive mode HOMEBREW_NO_ASK
# suppresses the install-plan confirmation prompt Homebrew 6.0 made the default
# (it stops on transitive deps and waits for y/n, which would hang). Interactive
# runs leave it on, so the user can see and answer the plan.
brew::_run_install() {
  if input::is_interactive >/dev/null; then
    brew install "$@"
  else
    HOMEBREW_NO_ASK=1 brew install "$@"
  fi
}

# A real install changes what `brew list` reports, but the per-kind cache was
# warmed before it ran. Drop the cache so the next query re-fetches — otherwise
# same-run introspection (e.g. "is the formula we just installed present?", which
# postgres::introspect::instance_version depends on) reads a stale, pre-install
# list and silently finds nothing.
brew::_invalidate_installed() {
  case "$1" in
    formula) _MK_BREW_FORMULA_CACHED=0 ;;
    cask)    _MK_BREW_CASK_CACHED=0 ;;
  esac
}

# Start/restart a formula's background service. SCOPE (default: system) selects how
# it runs on darwin:
#   system — `sudo brew services` registers a root LaunchDaemon that loads with no
#            GUI session. Right for headless always-on daemons.
#   user   — a plain `brew services` per-user LaunchAgent. Required for services
#            that refuse to run as root (e.g. syncthing); it loads only with an
#            active login (GUI) session, so such a host must auto-login.
# linux: brew refuses to run under sudo (it can't fetch the formula API as root),
# so brew runs as the invoking user and lingering keeps the user's systemd service
# alive across logout and reboot — the headless equivalent. SCOPE doesn't change
# Linux (its services are always user-level). All local-idempotent, no consent gate.
brew::start_service()   { brew::_service start   "$1" "${2:-system}"; }
brew::restart_service() { brew::_service restart "$1" "${2:-system}"; }

brew::_service() {
  local action="$1" formula="$2" scope="${3:-system}" family
  family="$(context::get os.family)"
  case "$family" in
    darwin)
      if [ "$scope" = user ]; then
        "$(brew::_bin)" services "$action" "$formula"
      else
        sudo "$(brew::_bin)" services "$action" "$formula"
      fi
      ;;
    linux)
      sudo loginctl enable-linger "$(id -un)"
      "$(brew::_bin)" services "$action" "$formula"
      ;;
    *) lifecycle::fail "brew::_service: unsupported os.family '$family'" ;;
  esac
}

# brew::_is_installed KIND NAME — is the named formula/cask already present?
brew::_is_installed() {
  local kind="$1" name="$2"
  # Warm cache in the current shell so the *_CACHED flag propagates; the
  # subshell for command substitution would otherwise never update it.
  brew::_installed "$kind" >/dev/null
  grep -qxF "$name" <<< "$(brew::_installed "$kind")"
}

# Absolute path to the brew binary. Callers running brew under sudo need this:
# sudo's secure_path drops the Homebrew prefix, so a bare `brew` won't resolve.
brew::_bin() {
  command -v brew
}

brew::_install_homebrew() {
  logging::info "Installing Homebrew..."
  if input::is_interactive >/dev/null; then
    brew_core::run_official_installer ""
  else
    brew_core::run_official_installer 1
  fi
  brew_core::setup_path
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
