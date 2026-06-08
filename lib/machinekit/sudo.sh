#!/usr/bin/env bash
# Sudo credential management. Sourced, not executed.
# Caller is responsible for `set -euo pipefail`.
[ -n "${_MK_SUDO_LOADED:-}" ] && return 0
_MK_SUDO_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/input.sh"

# Probe with `sudo -n -v` first so we don't interrupt the user mid-run.
# If credentials are already cached, start the keep-alive and return silently.
# Keep-alive re-validates every 60 seconds so the cache stays warm across
# sudo's default 5-minute timestamp_timeout. Dry-run skips the keep-alive
# because no actual sudo operations run in preview mode.
sudo::ensure() {
  if sudo -n true 2>/dev/null; then
    sudo::keepalive_start
  elif input::is_dry_run; then
    logging::warn "sudo credentials not currently cached. A real (non-dry-run)"
    logging::warn "apply would prompt (interactive) or hard-fail (non-interactive)."
  elif input::is_interactive >/dev/null; then
    logging::info "Pre-warming sudo credentials so prompts don't interrupt later steps..."
    sudo -v
    sudo::keepalive_start
  else
    logging::error "sudo access is required but not available in non-interactive mode."
    logging::error "Options:"
    logging::error "  1. Pre-cache sudo creds, then re-run within 5 minutes:"
    logging::error "       sudo -v && bin/machinekit apply --non-interactive ..."
    logging::error "  2. Configure passwordless sudo for this user (in /etc/sudoers.d/)"
    exit 1
  fi
}

# Idempotent: only one keep-alive per script run.
sudo::keepalive_start() {
  [ -n "${MK_SUDO_KEEPALIVE_PID:-}" ] && return 0

  ( while true; do sudo -n -v 2>/dev/null || exit; sleep 60; done ) &
  MK_SUDO_KEEPALIVE_PID=$!
  lifecycle::register_cleanup sudo::keepalive_stop
}

sudo::keepalive_stop() {
  [ -n "${MK_SUDO_KEEPALIVE_PID:-}" ] || return 0
  kill "$MK_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$MK_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  unset MK_SUDO_KEEPALIVE_PID
}
