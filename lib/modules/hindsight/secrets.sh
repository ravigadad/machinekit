#!/usr/bin/env bash
# hindsight secrets — shared secret resolution for the hindsight modules.
#
# Both hindsight_server and the hindsight_integration::<agent> modules draw
# secrets from one named-secret namespace: hindsight/<name> (a sibling of
# tailscale's, resolved via secrets::resolve — an age-encrypted pool file or a
# secrets-manager reference, whichever backend actually holds it; this file
# never knows or cares which). Each secret is provide-or-generate — the
# age-key idiom: a provided secret is used; an absent one is generated. The
# fleet's shared secret is the tenant API key, which every box must match:
# whichever box is provisioned first may generate it, and the rest provide the
# carried value.

# Holds only hindsight's own secret namespace.
_HINDSIGHT_SECRET_NAMESPACE="hindsight"

# The bare logical secret name, e.g. hindsight/db_password. Single source of
# it; error messages and the other functions here reuse it.
hindsight::secrets::name() {
  printf '%s/%s\n' "$_HINDSIGHT_SECRET_NAMESPACE" "$1"
}

# True when the named secret is provided (vs. to be generated). The caller
# asks this separately from resolve when it must distinguish a provided value
# from a freshly generated one (e.g. to message about generation).
hindsight::secrets::provided() {
  secrets::present "$(hindsight::secrets::name "$1")"
}

# Resolves a secret to its value on stdout: the provided secret if present,
# otherwise a freshly generated token. Plaintext goes to stdout only, so the
# caller controls where (if anywhere) it lands on disk.
hindsight::secrets::resolve() {
  local name="$1"
  if hindsight::secrets::provided "$name"; then
    secrets::resolve "$(hindsight::secrets::name "$name")"
  else
    hindsight::secrets::_generate_token
  fi
}

# A random opaque token for a generated secret (tenant key / db password). hex so
# it is safe everywhere it lands: a libpq URL, a bearer header, a shell env file.
hindsight::secrets::_generate_token() {
  openssl rand -hex 32
}
