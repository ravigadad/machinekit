#!/usr/bin/env bash
# hindsight secrets — shared secret resolution for the hindsight modules.
#
# Both hindsight_server and the hindsight_integration::<agent> modules draw
# secrets from one blueprint pool: secrets/hindsight/<name>.age (a sibling of
# tailscale's pool, outside the home pipeline). Each secret is provide-or-
# generate — the age-key idiom: a
# provided .age is decrypted and used; an absent one is generated. The fleet's
# shared secret is the tenant API key, which every box must match: whichever box
# is provisioned first may generate it, and the rest provide the carried value.

_HINDSIGHT_SECRET_DIR="secrets/hindsight"

# Blueprint-relative path of a pool secret, e.g. secrets/hindsight/db_password.age.
# Single source of the path shape; error messages and the path helper reuse it.
hindsight::secrets::rel() {
  printf '%s/%s.age\n' "$_HINDSIGHT_SECRET_DIR" "$1"
}

hindsight::secrets::path() {
  printf '%s/%s\n' "$(blueprints::dir)" "$(hindsight::secrets::rel "$1")"
}

# True when the named secret is provided in the pool (vs. to be generated). The
# caller asks this separately from resolve when it must distinguish a provided
# value from a freshly generated one (e.g. to message about generation).
hindsight::secrets::provided() {
  [ -f "$(hindsight::secrets::path "$1")" ]
}

# Resolves a pool secret to its value on stdout: the decrypted provided secret if
# present, otherwise a freshly generated token. Plaintext goes to stdout only, so
# the caller controls where (if anywhere) it lands on disk.
hindsight::secrets::resolve() {
  local name="$1"
  if hindsight::secrets::provided "$name"; then
    age::decrypt "$(hindsight::secrets::path "$name")"
  else
    hindsight::secrets::_generate_token
  fi
}

# A random opaque token for a generated secret (tenant key / db password). hex so
# it is safe everywhere it lands: a libpq URL, a bearer header, a shell env file.
hindsight::secrets::_generate_token() {
  openssl rand -hex 32
}

# Loud announcement, emitted every time the fleet tenant key is generated (on a
# server or an integration host — whichever box is provisioned first). The tenant
# key is the one secret every box must share, so the user has to carry it to the
# others. Never prints the value (age-key style). The optional FILE/FIELD note
# where it landed locally; the call to action — save it to the pool — is constant.
hindsight::secrets::announce_generated_tenant() {
  local file="${1:-}" field="${2:-}" where=""
  [ -n "$file" ] && where=" in $file${field:+ ($field)}"
  logging::banner warn "Generated the fleet tenant API key${where}.
Save it into $(hindsight::secrets::rel tenant_api_key) and copy it to your other
machines — every hindsight box (server and integrations) must share this key."
}
