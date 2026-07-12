#!/usr/bin/env bash
# secrets_manager — capability module for external secrets-manager backends
# (e.g. Infisical). Unlike container_manager/tool_version_manager, there is no
# universal default satisfier — no secrets manager is a sensible default for
# every fleet — so ::requires (reached only when something needs the
# capability and no explicit satisfier was listed in modules = [...]) fails
# with a clear recipe rather than silently picking one.

secrets_manager::is_capability() { return 0; }

# secrets_manager::fetch REFERENCE — the plaintext value REFERENCE addresses,
# via whichever satisfier is active. The one stable function every caller
# (secrets.sh, age.sh) uses; no caller ever names a concrete satisfier.
secrets_manager::fetch() {
  local reference="$1" satisfier
  satisfier=$(modules::capability_satisfier secrets_manager) \
    || lifecycle::fail "secrets_manager: no secrets-manager module is active — add one (e.g. infisical) to modules = [...]."
  "${satisfier}::fetch" "$reference"
}

# secrets_manager::ensure_ready — ready the active satisfier for use (install,
# authenticate, whatever it needs before presence checks and fetches). Runs before
# any module resolves a secret, so presence can be answered truthfully. A no-op
# when no satisfier is active.
secrets_manager::ensure_ready() {
  local satisfier
  satisfier=$(modules::capability_satisfier secrets_manager) || return 0
  "${satisfier}::ensure_ready"
}

# secrets_manager::has NAME — true when the active satisfier holds NAME. Lets
# secrets::backend_for report a manager-backed secret as present only when it
# truly exists. False when no satisfier is active (a caller only reaches here
# once capability_active has confirmed one, so that is a defensive floor).
secrets_manager::has() {
  local name="$1" satisfier
  satisfier=$(modules::capability_satisfier secrets_manager) || return 1
  "${satisfier}::has" "$name"
}

# secrets_manager::has_reference REFERENCE — true when the active satisfier holds
# the secret an explicit REFERENCE addresses. The reference counterpart to ::has:
# an explicit ref may point at any project/env, so it can't be answered from a
# bare name, and its presence is confirmed against what readiness verified. Same
# defensive false-when-none floor as ::has.
secrets_manager::has_reference() {
  local reference="$1" satisfier
  satisfier=$(modules::capability_satisfier secrets_manager) || return 1
  "${satisfier}::has_reference" "$reference"
}

secrets_manager::requires() {
  lifecycle::fail "secrets_manager: a secret references a secrets-manager reference, but no secrets-manager module is active — add one (e.g. infisical) to modules = [...]."
}

secrets_manager::install() { :; }
