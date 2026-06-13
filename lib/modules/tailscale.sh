#!/usr/bin/env bash
# tailscale — installs Tailscale and, on tagged service devices, joins the tailnet.
#
# Tailscale draws a hard line: a device is either owned by a user OR carries a
# tag, never both. The [module.tailscale] `tag` key is the discriminator:
#   tag set   → headless service device. brew formula (daemon, no GUI);
#               machinekit joins the tailnet itself via an age-encrypted OAuth
#               client secret, advertising the tag. Set-and-forget.
#   tag unset → user device. On macOS, the brew cask (menu-bar GUI app); on
#               Linux the formula (no brew GUI app exists). The human signs in.
#
# So the cask is only the macOS GUI convenience: it is used solely for an
# attended Mac (untagged AND darwin). Everything else — tagged anywhere, or any
# Linux device — installs the formula.
#
# Joining is an outside-world mutation, so it is consent-gated: interactive
# confirmation, or MACHINEKIT_TAILSCALE_JOIN=1 for unattended runs.

# Encrypted secrets live in the blueprint-global secrets pool — a sibling of
# common/ and machine_types/, outside the machine-type cascade — namespaced by
# service then tenancy: secrets/<service>/<tenancy>.age. For tailscale the
# tenancy is the tailnet (config key `tailnet`, default "default"), so the path
# is secrets/tailscale/<tailnet>.age. Outside home/, so it bypasses the home
# transform pipeline; the module decrypts in memory at join time, keeping the
# plaintext off disk.
_TAILSCALE_SECRET_DIR="secrets/tailscale"

tailscale::requires() { printf 'age\n'; }

# Tagged devices can only join if their encrypted secret is present; fail early
# and clearly rather than at join time. Untagged devices need no secret.
tailscale::preflight() {
  local tag
  tag=$(tailscale::_tag)
  [ -n "$tag" ] || return 0
  [ -f "$(tailscale::_secret_path)" ] || lifecycle::fail \
    "tailscale: tagged device (tag:$tag) needs an encrypted secret at $(tailscale::_secret_rel)"
}

# The cask token is `tailscale-app` (the GUI app); the formula is `tailscale`
# (the daemon + CLI) — distinct names, not two channels of one package.
tailscale::install() {
  logging::step "tailscale install"
  if tailscale::_use_cask; then
    tailscale::_install_cask
    return 0
  fi
  if [ "$(tailscale::_os_family)" = "linux" ]; then
    tailscale::_install_linux
    return 0
  fi
  # macOS, tagged/headless: the brew formula daemon.
  brew::install_formula tailscale
  if input::is_dry_run; then
    logging::dry_run "would start the tailscale system daemon"
    return 0
  fi
  tailscale::_start_daemon
}

# The cask can fail on a fresh Mac until its system extension is approved
# (System Settings → Privacy & Security) — an expected first-run hurdle, not a
# reason to abort the whole apply. Warn and continue; the re-run finishes it.
tailscale::_install_cask() {
  brew::install_cask tailscale-app || logging::warn \
    "tailscale: cask install failed. If it was the system-extension prompt, approve it in System Settings → Privacy & Security and re-run; otherwise see the error above."
}

# Linux: tailscaled must run as root with a system service — it manages netfilter
# (iptables/nft) and binds /var/run/tailscale, all of which fail unprivileged.
# brew on Linux can't deliver that: it refuses to run under sudo, and a user
# systemd unit runs tailscaled unprivileged, where it dies on permission errors.
# Tailscale's official installer adds the distro repo, installs tailscaled, and
# registers a proper root system service (started now and on boot) — the
# canonical Linux install. It runs its own sudo for the package steps. A local
# idempotent install, so no consent gate.
tailscale::_install_linux() {
  if input::command_exists tailscale; then
    logging::debug "tailscale: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install tailscale via the official installer (tailscale.com/install.sh)"
    return 0
  fi
  tailscale::_run_official_installer
}

tailscale::_run_official_installer() {
  curl -fsSL https://tailscale.com/install.sh | sh
}

# macOS only — Linux uses the official installer's system service (see above). The
# formula installs tailscaled stopped, and a headless Mac has no GUI login to
# start it. `sudo brew services start` registers the system LaunchDaemon
# (/Library/LaunchDaemons, RunAtLoad) so it comes up at boot with no desktop
# session — a plain `brew services start` makes a session-only LaunchAgent that
# never loads headless. Idempotent (exit 0 when already started). The cask path
# leaves the daemon to the GUI app.
tailscale::_start_daemon() {
  sudo "$(brew::_bin)" services start tailscale
}

# The cask (macOS GUI app) applies only to an attended Mac. Tagged devices and
# all Linux devices get the formula.
tailscale::_use_cask() {
  [ -z "$(tailscale::_tag)" ] && [ "$(tailscale::_os_family)" = "darwin" ]
}

# Joining happens after home::sync (post_apply) so the daemon is in place first.
# Only tagged devices auto-join; user devices get a one-line sign-in reminder.
tailscale::post_apply() {
  local tag
  tag=$(tailscale::_tag)
  if [ -z "$tag" ]; then
    tailscale::_signin_reminder
    return 0
  fi
  tailscale::_join "$tag"
}

# How a user signs in differs by platform: the GUI app on macOS, the CLI on
# Linux (where no brew GUI app exists). A message only — no action to consent to.
tailscale::_signin_reminder() {
  if [ "$(tailscale::_os_family)" = "darwin" ]; then
    logging::info "tailscale: open the Tailscale app and sign in to join your tailnet."
  else
    logging::info "tailscale: run 'sudo tailscale up' to sign in and join your tailnet."
  fi
}

tailscale::_join() {
  local tag="$1"
  if tailscale::_is_connected; then
    logging::info "tailscale: already connected to the tailnet; nothing to do."
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would join the tailnet as tag:$tag via its encrypted secret"
    return 0
  fi
  local consent
  consent=$(context::get "tailscale.join" --default false --coerce boolean \
    --prompt "Join the tailnet now as tagged device tag:$tag? (y/n)")
  if [ "$consent" != "true" ]; then
    logging::warn "tailscale: join not consented; skipping. Set MACHINEKIT_TAILSCALE_JOIN=1 to join."
    return 0
  fi
  local secret
  secret=$(age::decrypt "$(tailscale::_secret_path)")
  tailscale::_up "$secret" "$tag"
  logging::success "tailscale: joined the tailnet as tag:$tag."
}

# Brings the tagged device up. Two non-obvious things:
#  - The secret goes in via stdin (file:/dev/stdin), never argv, so it can't
#    leak through the process table. sudo passes stdin through; a process-sub
#    fd would be closed by sudo's closefrom, and a temp file would touch disk —
#    stdin avoids both (verified in a VM).
#  - sudo resets PATH to secure_path (no Homebrew prefix), so hand it the
#    absolute binary path, not a bare `tailscale`.
# ?ephemeral=false makes the OAuth-minted device persistent (the param defaults
# to true); confirmed end-to-end against a real OAuth client secret. It is parsed
# only for OAuth secrets — appending it to a plain auth key invalidates the key.
tailscale::_up() {
  local secret="$1" tag="$2"
  printf '%s' "${secret}?ephemeral=false" \
    | sudo "$(tailscale::_bin)" up --auth-key file:/dev/stdin --advertise-tags "tag:${tag}"
}

tailscale::_bin() {
  command -v tailscale
}

tailscale::_is_connected() {
  tailscale status >/dev/null 2>&1
}

tailscale::_tag() {
  config::get "module.tailscale.tag" --default ""
}

tailscale::_os_family() {
  context::get "os.family"
}

# The tenancy leaf: a user-chosen label for which tailnet's secret to use (not
# Tailscale's canonical, renameable name). Defaults to "default".
tailscale::_tailnet() {
  config::get "module.tailscale.tailnet" --default "default"
}

# Blueprint-relative secret path, e.g. secrets/tailscale/default.age — the
# single source of the path structure; preflight's error message reuses it.
tailscale::_secret_rel() {
  printf '%s/%s.age\n' "$_TAILSCALE_SECRET_DIR" "$(tailscale::_tailnet)"
}

tailscale::_secret_path() {
  printf '%s/%s\n' "$(blueprints::dir)" "$(tailscale::_secret_rel)"
}
