# Module setup

machinekit's built-in modules are activated by listing them (or a capability they satisfy) in your blueprint's `machinekit.toml` `modules = [...]`. **Most need nothing but that** — machinekit installs and configures them for you.

A few need **one-time external setup machinekit can't perform for you**: a third-party account, a secret you create, a key you register. Those are documented below. **If a module isn't listed here, activating it needs no out-of-band setup** — just list it and run `apply`.

This is the machinekit-specific quick start, not a replacement for each tool's own documentation; links point to the authoritative source. The current module set lives in [`lib/modules/`](../lib/modules/), with commented config examples in [`templates/blueprints/common/machinekit.toml`](../templates/blueprints/common/machinekit.toml).

---

## Before anything: a blueprints repo and an age key

These aren't modules, but everything else assumes them.

- **A blueprints repo.** Scaffold one with `machinekit generate <path>`, customize, and commit. See the [README quick start](../README.md#quick-start). A private repo cloned over SSH is handled by machinekit (it can install or generate the key and walk you through registering it); HTTPS uses git's own credentials.
- **An age key**, if any blueprint content is encrypted (the `secrets/` pool or `home/**.age` dotfiles) and you're not sourcing every one of those secrets from a secrets manager instead (see the `infisical` section below — in that case the age module and this whole section don't apply). machinekit installs the key on first apply — from a file you point at (`--existing-age-key-file`), fetched from a secrets manager when the age module is directed to source it (`[module.age] key_source_type = "secrets_manager"`, not merely an active manager), or generated with explicit consent (`--generate-age-key`). The **public** key is what you encrypt secrets *to*; print it with:

  ```bash
  age-keygen -y ~/.config/age/key.txt
  ```

  You create encrypted blueprint secrets yourself — machinekit only decrypts. For example, to put a secret in the pool:

  ```bash
  printf '%s' '<secret-value>' | age -r <your-age-public-key> -o secrets/<service>/<tenancy>.age
  ```

  (`printf` without a trailing newline matters for secrets consumed verbatim.) See [architecture.md § Secrets and key management](./architecture.md#secrets-and-key-management) for the two secret channels.

  To see which secrets your active modules actually need — which are required, which machinekit will generate if missing, and which are resolved (from the pool or a secrets manager) already — run `machinekit secrets list` (it applies nothing to the machine; when a secrets manager is active it authenticates to answer truthfully — see the infisical note below). To put one in the pool without hand-rolling the `age -r …` pipe (right recipient, right path), use `machinekit secrets put <name>` — the value comes from stdin, a file, or a hidden prompt, and it lands in your local blueprint working tree for you to commit:

  ```bash
  printf '%s' '<secret-value>' | machinekit secrets put <service>/<name> \
    --blueprints-dir <your-blueprints-checkout>
  ```

  If you already have the *encrypted* `.age` file (and your key can decrypt it), pass it with `--from-file` — machinekit verifies it and copies it in as-is rather than re-encrypting it.

---

## infisical — an alternative to the age pool for individual secrets

`infisical` is the `secrets_manager` capability's first satisfier: any secret a module declares (a tailscale OAuth secret, a hindsight key, a git_backup ssh_key, or the age key itself) can be sourced from [Infisical Cloud](https://infisical.com) instead of an age-encrypted pool file. Self-hosting Infisical is out of scope for this module — it always talks to Infisical's hosted API.

This section is the out-of-band setup — the Infisical account, identity, and secret values you create *outside* machinekit. The blueprint keys themselves (`auth_method`, `client_id`, `default_project_id`, `environment`, and per-secret `[secrets.manager_refs]`) are documented inline in the commented `[module.infisical]` block that `machinekit generate` writes into `common/machinekit.toml` — configure them there.

1. **Create an Infisical Cloud account and project** at [infisical.com](https://infisical.com), and note the project's ID (it becomes `default_project_id`).
2. **Choose an auth method** — typically machine-type layered (an attended personal machine wants `user`, a headless server wants `universal`):
   - `universal` (machine identity) — the only method that works non-interactively. In the Infisical dashboard, create a machine identity (Access Control → Identities), grant it at least Viewer on your project, and note its `client_id`/`client_secret`.
   - `user` (browser/SSO) — interactive only. No account setup beyond having a login (including via GitHub/Google/SSO if your org federates); `infisical login` opens a browser and the resulting session lives in your OS keyring.
3. **Provide the client secret at apply time** (universal auth) — never in the blueprint. Set the `MACHINEKIT_INFISICAL_CLIENT_SECRET` env var (there's no dedicated flag; env var or, on an interactive apply, a hidden prompt). This is root-of-trust material, the same tier as the age key's own bootstrap inputs.
4. **File the actual secret values in Infisical** (Secrets Manager → your project → the environment/name a `[secrets.manager_refs]` entry points at, or the upcased/underscored convention name in your `default_project_id`/`environment` when relying on the fallback), the same way you'd otherwise `age -r ... -o secrets/<service>/<name>.age` them into the pool.

`machinekit secrets list` shows each secret's resolved source (`pool`, `manager`, or `missing`) regardless of backend — it doesn't matter which one actually holds a given secret.

Because presence is checked against the manager itself, **listing infisical means machinekit authenticates to Infisical during preflight, during `secrets list`, and during an interactive `secrets put`** — a network round trip, and for `user` auth a browser login when your keyring session has lapsed (Infisical Cloud sessions last ~10 days, so this is occasional, not every run). This also happens under `apply --dry-run`: the login is the one outward action a dry run takes, and machinekit says so — nothing else is mutated. If you can't reach Infisical or complete the login, preflight fails rather than guessing a secret's source.

---

## git — register your SSH key with your git host

The git module sets your identity (`user.name` / `user.email` from `[module.git]` or a prompt) and machinekit's SSH handling can install or generate an SSH key. The part **you** do, once per host:

1. Have an account at your git host (GitHub, GitLab, …).
2. Add the public key to that account (Settings → SSH keys). On generation machinekit prints the key and pauses so you can paste it in; for an existing key, add it the same way. This is the host's normal "add an SSH key" flow.

No setup is needed if you only clone public repos over HTTPS.

---

## tailscale — tagged (headless) devices

A **user device** (a laptop you sit at — no `tag` in `[module.tailscale]`) needs **no pre-setup**: machinekit installs the client and you sign in yourself afterward (the GUI app on macOS, `sudo tailscale up` on Linux).

A **tagged device** (a headless server — `tag = "..."`) is joined by machinekit itself using an OAuth client secret — an age-encrypted pool file (below) or a secrets-manager reference (see `infisical`) — so you set that up once in the Tailscale admin console:

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

---

## hindsight_server — an LLM provider key, and the shared tenant key

`hindsight_server` runs a self-hosted [Hindsight](https://github.com/vectorize-io/hindsight) memory API as a container against the host postgres (the container runtime and postgres are pulled in automatically). List it in `modules` only on the machine that should be the memory server. Its secrets are named `hindsight/*` (resolved from the blueprint pool or, if configured, a secrets manager — see `infisical`):

1. **Pick an LLM provider and supply its API key (required — machinekit can't make one).** Set `[module.hindsight_server] llm_provider = "..."` (no default) and encrypt the matching key into the pool:

   ```bash
   printf '%s' '<llm-api-key>' | age -r <your-age-public-key> -o secrets/hindsight/llm_api_key.age
   ```

2. **The fleet tenant key — shared by every hindsight box.** If `secrets/hindsight/tenant_api_key.age` is absent, machinekit generates one on first apply and **announces it** (the value, never re-printed): save it into the pool and reuse the *same* file on every other hindsight machine — server and integration hosts must all carry one key. If you already have it, seed it like the LLM key above.

3. **Optional:** `secrets/hindsight/db_password.age` (generated if absent) and `secrets/hindsight/cp_access_key.age` (the control-plane web-UI password; absent → you're prompted at an interactive apply, or one is generated and announced).

machinekit assembles these into a create-once `~/.config/hindsight/hindsight.env` (mode 600). To rotate or repoint, delete that file and re-apply. The full config surface (provider, model, ports, image overrides) is the commented `[module.hindsight_server]` block in [`templates/blueprints/common/machinekit.toml`](../templates/blueprints/common/machinekit.toml); for Hindsight itself, see the [upstream docs](https://github.com/vectorize-io/hindsight).

---

## hindsight_integration — a reachable server and the shared tenant key

`hindsight_integration` wires this machine's coding agents (chosen with `integrations = [...]`) to a Hindsight server. Setup is just connectivity:

1. **Point at the server.** Set either `server_host` (a reachable host — typically its tailnet MagicDNS name) or `server_url` (a full URL, for https, a path, or a hosted Hindsight) in `[module.hindsight_integration]`.
2. **Share the tenant key.** The same `hindsight/tenant_api_key` secret the server uses — every box must match (see hindsight_server above). If this machine is provisioned before the server, machinekit generates and announces the key here; carry it to the server too.

Everything else (which banks to auto-recall or expose as tools) is plain config in the commented block in [`templates/blueprints/common/machinekit.toml`](../templates/blueprints/common/machinekit.toml). No accounts to create; an agent's own sign-in (e.g. `claude` on first run) is separate and yours to do.

**Optional — bank missions/dispositions.** If you add `[module.hindsight_integration.additional_banks.<name>]` tables, machinekit applies each bank's mission/disposition config to the tenant on apply (an idempotent upsert, using Hindsight's own field names). Banks are tenant-scoped, so this runs from whichever box carries the config. Because it writes to the tenant, it is **consent-gated** — an interactive yes, or `MACHINEKIT_HINDSIGHT_INTEGRATION_CONFIGURE_BANKS=1` unattended — and it uses the shared `hindsight/tenant_api_key` read-only, so that key must already be shared (not just freshly generated on this box). If the server isn't reachable yet, the step is skipped and applies on the next run.

---

## agents_config_setup — a source for the agents-config directory

`agents_config_setup` ensures the shared agents-config directory (default `~/.agents`) is on the machine, seeding it from a source when it's absent. It owns the canonical `dir` key that `agents_config_harnesses` reads.

Point it at where your agents config lives with `source` under `[module.agents_config_setup]` — a git URL, a local git repo, or a plain directory to copy (the same source handling as the blueprints fetch; override the auto-detected protocol with `source_protocol = "git"` or `"cp"` if needed):

```toml
[module.agents_config_setup]
source = "git@github.com:you/agents.git"
# dir = "~/.agents"          # override only to use a non-default location
# source_protocol = "git"           # override only if auto-detection guesses wrong
```

A private git source needs the same SSH access blueprints do — register your key with your host (see the git section above). Seeding only fills an **absent or empty** dir; if the directory already exists and has contents, machinekit leaves it untouched (so syncing it on by other means, or running again, is safe). If the dir is absent and no `source` is set, preflight stops with a message.

## agents_config_harnesses — a populated agents-config directory

`agents_config_harnesses` wires your agents to a shared agents-config directory (default `~/.agents`) so they all load the same instructions and skills. machinekit creates the projection; **you provide the directory's contents** — let `agents_config_setup` seed it from a source (above), populate it yourself, or sync it onto the machine. It holds:

- a top-level `AGENTS.md` — your instructions, loaded every session;
- `skills/<name>/SKILL.md` files — skills the agent loads when the task is relevant;
- optionally, identity files (`SOUL.md`, `IDENTITY.md`, `USER.md`) — projected into the persistent-assistant harnesses that read them (below).

Then list `agents_config_harnesses` in `modules`, choose agents with `harnesses` (e.g. `["claude_code", "codex", "opencode"]`), and apply. Each harness projects only what it reads — a coding agent gets `AGENTS.md` and skills; a persistent assistant also gets the identity files:

- **claude_code** symlinks `~/.claude/skills` → `<dir>/skills` and adds an `@<dir>/AGENTS.md` import to `~/.claude/CLAUDE.md`.
- **codex** and **opencode** read skills from the shared dir natively, so the projection is just a symlink of their global `AGENTS.md` (`~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`) to the dir's.
- **openclaw** and **hermes** are persistent-assistant CLIs that read identity files. openclaw symlinks `SOUL.md`, `IDENTITY.md`, `USER.md`, `AGENTS.md`, and `skills` into its default workspace (`~/.openclaw/workspace`); hermes symlinks the single file it reads, `~/.hermes/SOUL.md`. Each entry is projected only once you've authored its source file — and openclaw's, only once the workspace exists (created by openclaw's own onboarding). Selecting either harness also installs its CLI.

(Cursor has no global instructions file to project to — its global rules live in the settings UI — so it isn't a harness here; its skills are still read from the shared dir natively.)

One caveat worth knowing: any of these projections refuses to clobber a pre-existing real file in its place (a hand-kept `~/.claude/skills` directory, or a real `AGENTS.md` you already wrote) — it stops with a message rather than overwrite. Move that content into `<dir>` (where it gets synced and projected too) and re-apply.

## syncthing — pairing device IDs across machines

`syncthing` keeps a set of folders replicated peer-to-peer across your machines — it's how the shared agents-config dir stays live across the fleet, though it's generic about what it syncs. Discovery defaults to **tailnet-only** (`discovery = "tailnet"`): machinekit hardens the daemon off the public discovery servers and relies on the static peer addresses you give it (typically tailnet MagicDNS names), so the machines need to be on the same tailnet. Set `discovery = "default"` to keep Syncthing's own discovery (global/LAN/relays) for non-tailnet topologies.

The topology is **hub-and-spoke**: one always-on machine is the hub (`hub = true`); every other machine is a client that points at the hub and learns the rest *through* it. Device IDs are generated on first run, so some ordering is unavoidable — but only the **hub's** ID ever needs copying:

1. **Apply on the hub first.** It announces the hub's device ID. The hub pre-lists no clients.
2. **Give that hub ID to each client** (`[[module.syncthing.peers]]`, `introducer = true`) and apply. The client connects to the hub and lands in the hub's *pending* list.
3. **Re-apply on the hub** to approve the joiners. The hub discovers their IDs from the connection (you never transcribe a client ID), adds them, and shares the folders. Adding a machine later is just steps 2–3 for that one machine; the *other* clients update themselves.

Joining is consent-gated at every step — confirm interactively, or set `MACHINEKIT_SYNCTHING_JOIN=1` for an unattended run. Until consent, the daemon installs and idles with its folders local-only. (Syncthing has no "accept any device" — a deliberate approval on the hub is the security floor.)

**How `introducer` actually works:** it's a one-directional flag set on the *client's* entry for the hub, meaning "I trust this peer to introduce *its* devices to me." So each client marks the hub, and the hub — which shares the folder with every approved client — introduces them to one another. The hub itself needs no introducer flag. This is what spares you the N² of pairing every client with every other; you only ever pair clients with the hub.

**Hub** config:

```toml
[module.syncthing]
hub = true                    # accept joiners instead of pre-listing them
[[module.syncthing.folders]]
id = "agents"                 # stable + identical across machines for the same folder
path = "~/.agents"
```

**Client** config — just the hub:

```toml
[module.syncthing]
[[module.syncthing.folders]]
id = "agents"
path = "~/.agents"

[[module.syncthing.peers]]
device_id = "HUB-DEVICE-ID"   # the hub's announced ID (the only ID you copy)
address = "tcp://server:22000" # the hub's tailnet address (or "dynamic")
introducer = true             # learn the other clients through the hub
```

**Ignore patterns.** Each folder gets a machinekit-managed `.stignore` by default — a delimited block holding junk that should never replicate (`(?d).DS_Store` and friends; the `(?d)` marks them deletable so they can't block a directory removal). Per folder you can add your own with `ignore_patterns = [...]` (kept above the defaults, so a `!`-negation wins Syncthing's first-match precedence), drop the built-ins with `add_default_ignores = false`, or hand the file entirely back to yourself with `manage_stignore = false`. machinekit only ever rewrites its own block; everything else in the file is yours, and deleting the block just gets it restored next apply.

**Conflict notifications.** Syncthing silently renames the losing side of a concurrent same-file edit to `*.sync-conflict-*` and never surfaces it on its own. Whenever any folders are configured, machinekit installs a standing scheduled scan of them (no extra setup needed) that re-fires a notify hook on every run while any conflict files remain — a nag until you resolve them, not a one-time ping you might miss:

```toml
[module.syncthing]
# interval = 300               # seconds between conflict scans
# notify = "/path/to/notify-hook"  # run with a message on trouble; default: logger/journald
```

## git_backup — an SSH key for the folders you back up

`git_backup` periodically pushes one or more working dirs to git remotes, so a live, replicated dir gets durable history (Syncthing, for example, propagates deletions, so it isn't itself a backup). It's generic — it backs up whatever folders you list and knows nothing about what's in them. The agents-config dir is the typical case, but any git-pushable folder works.

Each folder is **single-writer**: back a given folder up from exactly one machine — usually the always-on server — or the machines race its one downstream branch. One service runs on that machine and pushes every configured folder on the interval; a folder whose push hits an unexpected divergence rebases, and if that conflicts it aborts and notifies, leaving both sides untouched.

List the folders under `[module.git_backup]`:

```toml
[module.git_backup]
ssh_key = "agents"             # module-level default key name (optional; see below)
# interval = 300               # seconds between backup runs
# notify = "/path/to/notify-hook"  # run with a message on trouble; default: logger/journald

[[module.git_backup.folders]]
path = "~/.agents"
remote = "git@github.com:you/agents.git"
# ssh_key = "agents"           # per-folder override of the module default

[[module.git_backup.folders]]
path = "~/notes"
remote = "git@github.com:you/notes.git"
```

**The push key.** A folder pushes over whatever SSH key you name. `ssh_key` is the name of a secret in the pool (or a secrets manager, if configured — see `infisical`) — set it module-wide and/or override it per folder. machinekit resolves it on the server (never the home pipeline) to a private key file the push uses:

```
git_backup/ssh_keys/<name>       # an SSH private key authorized to push to that folder's remote
                                  # as a pool file: secrets/git_backup/ssh_keys/<name>.age
```

Any key with write access works — a GitHub deploy key, your own key, whatever. Generate one (`ssh-keygen -t ed25519 -f <name> -N ""`), authorize its public half on the remote, then age-encrypt the private half into the pool path above (or file it in your secrets manager under that name). **Omit `ssh_key` entirely** to push over ambient SSH (an agent or an on-disk default key) — then no secret is needed. When any `ssh_key` is named, preflight requires it and pulls in whichever backend actually resolves it (`age` and/or `secrets_manager`) automatically.

**Ignore patterns.** Each folder gets a machinekit-managed `.gitignore` by default, so the backup repo never carries junk — `.DS_Store` and, notably, `.stversions/` (Syncthing's version buffer), which git would otherwise commit. So pairing a `syncthing` folder with a `git_backup` folder for the same path just works; you don't list `.stversions/` yourself. The same three knobs apply per folder: `ignore_patterns = [...]` (your patterns, above the defaults), `add_default_ignores = false`, and `manage_gitignore = false` (leave the file to you). machinekit rewrites only its own delimited block; as with any `.gitignore` it affects only untracked files, so anything already committed needs a manual `git rm --cached`. The `.gitignore` is written only if the folder already exists — git_backup never creates a folder another module is meant to seed.
