# Module setup

machinekit's built-in modules are activated by listing them (or a capability they satisfy) in your blueprint's `machinekit.toml` `modules = [...]`. **Most need nothing but that** — machinekit installs and configures them for you.

A few need **one-time external setup machinekit can't perform for you**: a third-party account, a secret you create, a key you register. Those are documented below. **If a module isn't listed here, activating it needs no out-of-band setup** — just list it and run `apply`.

This is the machinekit-specific quick start, not a replacement for each tool's own documentation; links point to the authoritative source. The current module set lives in [`lib/modules/`](../lib/modules/), with commented config examples in [`templates/blueprints/common/machinekit.toml`](../templates/blueprints/common/machinekit.toml).

---

## Before anything: a blueprints repo and an age key

These aren't modules, but everything else assumes them.

- **A blueprints repo.** Scaffold one with `machinekit generate <path>`, customize, and commit. See the [README quick start](../README.md#quick-start). A private repo cloned over SSH is handled by machinekit (it can install or generate the key and walk you through registering it); HTTPS uses git's own credentials.
- **An age key**, if any blueprint content is encrypted (the `secrets/` pool or `home/**.age` dotfiles). machinekit installs the key on first apply — from a file you point at (`--existing-age-key-file`) or generated with explicit consent (`--generate-age-key`). The **public** key is what you encrypt secrets *to*; print it with:

  ```bash
  age-keygen -y ~/.config/age/key.txt
  ```

  You create encrypted blueprint secrets yourself — machinekit only decrypts. For example, to put a secret in the pool:

  ```bash
  printf '%s' '<secret-value>' | age -r <your-age-public-key> -o secrets/<service>/<tenancy>.age
  ```

  (`printf` without a trailing newline matters for secrets consumed verbatim.) See [architecture.md § Secrets and key management](./architecture.md#secrets-and-key-management) for the two secret channels.

---

## git — register your SSH key with your git host

The git module sets your identity (`user.name` / `user.email` from `[module.git]` or a prompt) and machinekit's SSH handling can install or generate an SSH key. The part **you** do, once per host:

1. Have an account at your git host (GitHub, GitLab, …).
2. Add the public key to that account (Settings → SSH keys). On generation machinekit prints the key and pauses so you can paste it in; for an existing key, add it the same way. This is the host's normal "add an SSH key" flow.

No setup is needed if you only clone public repos over HTTPS.

---

## tailscale — tagged (headless) devices

A **user device** (a laptop you sit at — no `tag` in `[module.tailscale]`) needs **no pre-setup**: machinekit installs the client and you sign in yourself afterward (the GUI app on macOS, `sudo tailscale up` on Linux).

A **tagged device** (a headless server — `tag = "..."`) is joined by machinekit itself using an age-encrypted OAuth client secret, so you set that up once in the Tailscale admin console:

1. Sign in at [login.tailscale.com](https://login.tailscale.com) — the account owns your tailnet.
2. **Access Controls** (policy file): declare the tag's owner, e.g. `"tagOwners": { "tag:server": ["autogroup:admin"] }`.
3. **Settings → OAuth clients → Generate**: scope `auth_keys` (write), tagged with your tag (e.g. `tag:server`). Copy the client secret (shown once). OAuth client secrets don't expire — the point of using one for a set-and-forget box.
4. Encrypt it into the secrets pool, matching the machine's `tailnet` config (default `default`):

   ```bash
   printf '%s' '<oauth-client-secret>' | age -r <your-age-public-key> -o secrets/tailscale/default.age
   ```

Then `[module.tailscale] tag = "server"` and apply; machinekit joins the tailnet, advertising the tag. Optionally set `hostname = "..."` to pin the device's tailnet (MagicDNS) name so other machines can address it by a known name. Joining is consent-gated (interactive prompt, or `MACHINEKIT_TAILSCALE_JOIN=1`).

Reference: Tailscale docs on [tags](https://tailscale.com/kb/1068/tags), [OAuth clients](https://tailscale.com/kb/1215/oauth-clients), and [auth keys](https://tailscale.com/kb/1085/auth-keys).

---

## container_manager (orbstack / docker_ce)

No out-of-band account or secret. machinekit installs the platform default — OrbStack on macOS (brew cask), Docker Engine on Linux (the get.docker.com script, which machinekit runs with sudo). On macOS, OrbStack may ask for permissions on first launch; on Linux the daemon runs as root, so `docker` is invoked with sudo (the install script doesn't add you to the `docker` group). Nothing to do before `apply`.
