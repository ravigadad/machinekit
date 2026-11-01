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

## postgres (postgres_brew / postgres_app)

Nothing to do for the default. The `postgres` capability's default satisfier, `postgres_brew`, installs and runs PostgreSQL via Homebrew with no out-of-band setup — that's the case for most machines, including the memory server unless you say otherwise.

Only if you list `postgres_app` (macOS only) to use [Postgres.app](https://postgresapp.com) as your provider is there manual setup, because machinekit never drives Postgres.app's lifecycle — it only checks and provisions into a server you run:

1. **Install Postgres.app and start a server** *before* `apply`. By default machinekit provisions into whatever Postgres.app server is running on port 5432; if it finds no Postgres.app server there — or a non-Postgres.app postgres holding the port — it fails rather than provision into the wrong place.
2. **Pin versions/ports (optional).** With `[module.postgres.versions.primary]` and `version = 17`, `port = 5432` under it machinekit verifies that exact server is running (same table `postgres_brew` would *create*; `postgres_app` only *checks* it). Without it, any Postgres.app server on 5432 is accepted.

Extensions (e.g. `pgvector`, which `hindsight_server` uses) ship bundled with Postgres.app, so nothing extra is installed for them.

---

## hindsight_server — an LLM provider key, and the shared tenant key

`hindsight_server` runs a self-hosted [Hindsight](https://github.com/vectorize-io/hindsight) memory API as a container against the host postgres (the container runtime and postgres are pulled in automatically). List it in `modules` only on the machine that should be the memory server. Its secrets are named `hindsight/*` (resolved from the blueprint pool or, if configured, a secrets manager — see `infisical`):

1. **Pick an LLM provider and supply its API key (required — machinekit can't make one).** Set `[module.hindsight_server] llm_provider = "..."` (no default) and encrypt the matching key into the pool:

   ```bash
   printf '%s' '<llm-api-key>' | age -r <your-age-public-key> -o secrets/hindsight/llm_api_key.age
   ```

2. **The fleet tenant key — shared by every hindsight box.** If `secrets/hindsight/tenant_api_key.age` is absent, machinekit generates one on first apply into the server's `~/.config/hindsight/hindsight.env`, and the end-of-apply summary points you there (the value is never printed): copy it into the pool (or your secrets manager) and reuse the *same* key on every other hindsight machine — server and integration hosts must all carry one key. If you already have it, seed it like the LLM key above.

3. **Optional:** `secrets/hindsight/db_password.age` (generated if absent; machine-local, so it stays in the env file and is not surfaced) and `secrets/hindsight/cp_access_key.age` (the control-plane web-UI password; absent → you're prompted at an interactive apply, or one is generated into the env file and the end-of-apply summary tells you to retrieve it there to sign in).

machinekit assembles these into a create-once `~/.config/hindsight/hindsight.env` (mode 600). To rotate or repoint, delete that file and re-apply. The full config surface (provider, model, ports, image overrides) is the commented `[module.hindsight_server]` block in [`templates/blueprints/common/machinekit.toml`](../templates/blueprints/common/machinekit.toml); for Hindsight itself, see the [upstream docs](https://github.com/vectorize-io/hindsight).

---

## hindsight_integration — a reachable server and the shared tenant key

`hindsight_integration` wires this machine's coding agents (chosen with `integrations = [...]`) to a Hindsight server. Setup is just connectivity:

1. **Point at the server.** Set either `server_host` (a reachable host — typically its tailnet MagicDNS name) or `server_url` (a full URL, for https, a path, or a hosted Hindsight) in `[module.hindsight_integration]`.
2. **Share the tenant key.** The same `hindsight/tenant_api_key` secret the server uses — every box must match (see hindsight_server above). Provision the server first so the key exists, share it (pool or secrets manager), then the clients resolve it. If a client is applied before the key is shared, machinekit generates a stand-in into its agent config and the end-of-apply summary flags that the fleet key isn't in your secrets manager — add the shared key and re-apply.

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

A private git source needs the same SSH access blueprints do — register your key with your host (see the git section above). Seeding only fills an **absent or empty** dir; if the directory already exists and has contents, machinekit leaves it untouched (so syncing it on by other means, or running again, is safe). After a git seed the clone's `.git` is stripped, so the directory holds plain content rather than a live repo — keeping version-control history off the Syncthing mesh and leaving any repo on a backup machine to `git_backup`. If the dir is absent and no `source` is set, preflight stops with a message.

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
2. **Give that hub ID to each client** (a `[module.syncthing.peers.<key>]` entry with `introducer = true`) and apply. The client connects to the hub and lands in the hub's *pending* list.
3. **Re-apply on the hub** to approve the joiners. The hub discovers their IDs from the connection (you never transcribe a client ID), adds them, and shares the folders. Adding a machine later is just steps 2–3 for that one machine; the *other* clients update themselves.

Joining is consent-gated at every step — confirm interactively, or set `MACHINEKIT_SYNCTHING_JOIN=1` for an unattended run. Until consent, the daemon installs and idles with its folders local-only. (Syncthing has no "accept any device" — a deliberate approval on the hub is the security floor.)

**How `introducer` actually works:** it's a one-directional flag set on the *client's* entry for the hub, meaning "I trust this peer to introduce *its* devices to me." So each client marks the hub, and the hub — which shares the folder with every approved client — introduces them to one another. The hub itself needs no introducer flag. This is what spares you the N² of pairing every client with every other; you only ever pair clients with the hub.

**Hub** config:

```toml
[module.syncthing]
hub = true                    # accept joiners instead of pre-listing them

[module.syncthing.folders.agents]  # the key is the folder id: identical across machines
path = "~/.agents"
```

**Client** config — just the hub:

```toml
[module.syncthing.folders.agents]
path = "~/.agents"

[module.syncthing.peers.hub]
device_id = "HUB-DEVICE-ID"   # the hub's announced ID (the only ID you copy)
address = "tcp://server:22000" # the hub's tailnet address (or "dynamic")
introducer = true             # learn the other clients through the hub
```

**Sync direction.** A folder is two-way by default. Set `type` on a folder to change that — most usefully `type = "receiveonly"` on machines that hold a *replica* of a folder one machine owns: a change or deletion made on a receive-only replica is reverted rather than propagated, so the owner's copy can't be damaged from elsewhere. (`sendonly` and `receiveencrypted` are the other two Syncthing accepts.) The type is re-asserted on every apply, so a folder flipped by hand converges back to what the blueprint says.

```toml
[module.syncthing.folders.postgres-dumps]
path = "~/postgres-dumps"
type = "receiveonly"          # on every machine except the one writing the dumps
```

**Ignore patterns.** Each folder gets a machinekit-managed `.stignore` by default — a delimited block excluding two kinds of thing from replication: OS junk (`(?d).DS_Store` and friends, marked `(?d)` deletable so they can't block a directory removal) and version-control metadata (`.git`), which is deliberately *not* marked deletable — on a machine that also backs the folder up over git, its `.git` is a live repo Syncthing must neither replicate nor delete. Per folder you can add your own with `ignore_patterns = [...]`, drop the built-ins with `add_default_ignores = false`, or hand the file entirely back to yourself with `manage_stignore = false`. A machine type adds to a folder's inherited patterns with `additional_ignore_patterns = [...]` on the same folder. Syncthing applies the first pattern that matches, so the block is written most specific first — the type's additions, then `ignore_patterns`, then the defaults — and a `!` negation from a more specific layer wins. machinekit only ever rewrites its own block; everything else in the file is yours, and deleting the block just gets it restored next apply.

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

[module.git_backup.folders.agents]  # the key is only a handle for overrides
path = "~/.agents"
remote = "git@github.com:you/agents.git"
# ssh_key = "agents"           # per-folder override of the module default

[module.git_backup.folders.notes]
path = "~/notes"
remote = "git@github.com:you/notes.git"
```

**The push key.** A folder pushes over whatever SSH key you name. `ssh_key` is the name of a secret in the pool (or a secrets manager, if configured — see `infisical`) — set it module-wide and/or override it per folder. machinekit resolves it on the server (never the home pipeline) to a private key file the push uses:

```
git_backup/ssh_keys/<name>       # an SSH private key authorized to push to that folder's remote
                                  # as a pool file: secrets/git_backup/ssh_keys/<name>.age
```

Any key with write access works — a GitHub deploy key, your own key, whatever. Generate one (`ssh-keygen -t ed25519 -f <name> -N ""`), authorize its public half on the remote, then age-encrypt the private half into the pool path above (or file it in your secrets manager under that name). **Omit `ssh_key` entirely** to push over ambient SSH (an agent or an on-disk default key) — then no secret is needed. When any `ssh_key` is named, preflight requires it and pulls in whichever backend actually resolves it (`age` and/or `secrets_manager`) automatically.

**Ignore patterns.** Each folder gets a machinekit-managed `.gitignore` by default, so the backup repo never carries junk — OS cruft like `.DS_Store`, plus Syncthing's own machine-local artifacts (its version buffer, folder marker, and ignore file), which the mesh keeps to itself but git would otherwise commit. So pairing a `syncthing` folder with a `git_backup` folder for the same path just works; you don't list Syncthing's artifacts yourself. The same knobs apply per folder: `ignore_patterns = [...]`, `additional_ignore_patterns = [...]` (a machine type's additions), `add_default_ignores = false`, and `manage_gitignore = false` (leave the file to you). Git applies the last pattern that matches — the opposite of Syncthing — so this block is written most specific last: the defaults, then `ignore_patterns`, then the type's additions, and a `!` negation from a more specific layer wins. machinekit rewrites only its own delimited block; as with any `.gitignore` it affects only untracked files, so anything already committed needs a manual `git rm --cached`. The `.gitignore` is written only if the folder already exists — git_backup never creates a folder another module is meant to seed.

## offsite_backup — a remote repository, its credentials, and its password

`offsite_backup` periodically copies configured local paths to remote [restic](https://restic.net) repositories. It's generic — it backs up whatever paths you list and knows nothing about what produced the files. restic encrypts everything client-side before it leaves the machine, so the storage provider only ever holds ciphertext.

Each repository you declare gets its own paths, its own schedule, its own retention, and its own two secrets. **One repository with several paths is the usual shape** — restic groups snapshots by host and paths when it forgets, so each path gets the keep policy applied to it independently, and deduplication is shared across the whole repository. Declare a *second* repository only for what a second path in the first one can't express: a different destination, a different encryption key, or a different keep policy.

Three things need to exist per repository before you activate it, and none of them is something machinekit can create for you.

1. **A bucket (or other restic-supported destination), at whatever provider you like.** restic speaks S3-compatible object storage, plus SFTP, REST, and local paths; at the volumes this module is built for, providers differ by well under a dollar a month, so choose on how many vendors you want to hold and whether you care about object lock — not on price. The destination becomes the `repository` value in your blueprint, which is ordinary config, not a secret.

2. **Two secrets in the pool (or your secrets manager), namespaced by the repository's `name`:**

   ```
   offsite_backup/<name>/repository_password   # LOSE THIS AND THAT BACKUP IS UNREADABLE
   offsite_backup/<name>/credentials           # the backend's credentials, as KEY=value lines
   ```

   The credentials secret is carried **opaquely**: every restic backend reads different environment variables, so machinekit exports whatever `KEY=value` lines the file holds and never interprets them. For an S3-compatible backend that's two lines — and note these are what *every* S3 client calls them, not an indication that the destination is AWS:

   ```
   AWS_ACCESS_KEY_ID=<the key id>
   AWS_SECRET_ACCESS_KEY=<the application key>
   ```

   File both with `machinekit secrets put` (see the age-key section above), e.g. for a repository named `database_dumps`:

   ```bash
   printf '%s' '<a long random password>' \
     | machinekit secrets put offsite_backup/database_dumps/repository_password \
       --blueprints-dir <your-blueprints-checkout>
   printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' '<key id>' '<application key>' \
     | machinekit secrets put offsite_backup/database_dumps/credentials \
       --blueprints-dir <your-blueprints-checkout>
   ```

   Omit the credentials secret entirely for a destination that needs none (a local path, or SFTP over a key you already have). The repository password is always required.

3. **The repository itself, created once.** Creating it writes to the remote, so it's consent-gated like every other outward action: apply interactively and say yes, or set `MACHINEKIT_OFFSITE_BACKUP_INIT_REPOSITORY=1` for an unattended run. One yes covers every repository you've declared that doesn't exist yet, and machinekit only asks when at least one is actually absent — so re-applying later is silent. Decline, and the install still finishes and schedules everything; the repositories that don't exist just fail their runs, which the end of the apply tells you.

   To create one yourself instead:

   ```bash
   export RESTIC_REPOSITORY='<your repository string>'
   export RESTIC_PASSWORD_FILE=~/.config/machinekit/offsite_backup/<name>/repository_password
   set -a; . ~/.config/machinekit/offsite_backup/<name>/credentials; set +a
   restic init
   ```

Then configure the module. Module-level keys are defaults; any repository may override them:

```toml
[module.offsite_backup]
# schedule = "30 3 * * *"        # cron; when the backup-and-prune run fires
# check_schedule = "0 4 * * 0"   # cron; when the repository is verified
# keep_daily = 7                 # retention — see the warning below
# keep_weekly = 4
# keep_monthly = 12
# check_read_data = false        # true re-downloads every pack; slow, and the one
                                 # operation with real egress cost
# notify = "/path/to/notify-hook"  # run with a message on trouble; default: logger/journald

# A repository holding things that share a retention shape. Its key is its name
# (set `name` to override): lowercase letters, digits, and underscores, because it
# names this repository's secrets, its files, and its two service units — so pick
# it once and leave it alone.
[module.offsite_backup.repositories.database_dumps]
repository = "s3:s3.example-region.example.com/my-restic-bucket/database_dumps"

[module.offsite_backup.repositories.database_dumps.paths.dumps]  # the key is only a handle
path = "~/postgres-dumps"
max_age_hours = 36               # alarm if nothing under the path changed in that long

# A second repository exists for what a second path in the first one cannot
# express — here, a different keep policy. Any module-level key may be repeated
# on a repository to override it for that one alone.
[module.offsite_backup.repositories.logs]
repository = "s3:s3.example-region.example.com/my-restic-bucket/logs"
keep_daily = 7
keep_weekly = 2
keep_monthly = 0

[module.offsite_backup.repositories.logs.paths.example]
path = "/var/log/example"
```

**Name a repository for what it holds, not for the provider or the tool.** The name distinguishes one repository from another, so anything that would be true of all of them (`offsite`, the vendor, `machinekit`) carries no information — and a vendor name goes stale the moment you move the data. Mirroring the name in the repository string's last path segment, as above, keeps the bucket readable against the blueprint. Note that bucket *names* can't contain underscores on most providers (they become DNS labels), while the prefix after the bucket has no such restriction — so a hyphenated bucket holding snake_case prefixes is expected, not a mistake.

Each repository gets its own pair of services, labelled after its name (`offsite-backup-database-dumps`, `offsite-backup-database-dumps-check`).

**Retention deletes remote history, and it ships on by default.** Each run adds a full new copy of whatever is in the path, so with no retention at all a repository grows with the *square* of time. The defaults above (7 daily / 4 weekly / 12 monthly) are what stop that; whatever is in force for each repository is printed at the end of every apply. Raise them if you want more history — the cost of keeping every daily copy forever is roughly ten to thirty times the cost of the default policy. Because restic groups snapshots by path when forgetting, one policy covers every path in a repository *separately*: `keep_daily = 7` keeps seven dailies of each path, not seven between them.

**`max_age_hours` is per path, not per repository** — it's about the source directory's freshness, not the destination. If nothing under the path has changed inside that window, the run notifies. Whatever writes into the path can quietly stop while the upload keeps succeeding every night; nothing else would ever tell you.

**`check_schedule` is what verifies the remote.** A backup you have never read back is a guess. The weekly default check validates the repository's structure without re-downloading its data; `check_read_data = true` re-reads every pack, which is thorough and expensive — reach for it occasionally, not on a schedule.

**Provider wrinkles worth checking before you rely on a destination.**

- **Backblaze B2 needs a lifecycle rule, or retention silently does nothing.** restic's S3 backend *hides* obsolete files rather than deleting them, and B2 keeps — and bills for — every hidden version by default. Set the bucket's Lifecycle Settings to **"Keep only the last version of the file"**; without it `forget --prune` reclaims no space at all. ([restic docs](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)) Use B2's S3-compatible endpoint rather than restic's native `b2:` backend — both projects recommend it, because the native backend's error handling can hang instead of reporting. A bucket-restricted application key also needs **Allow List All Bucket Names** enabled, or B2 answers ordinary object requests with `403 AccessDenied` where restic expects a `404`.
- **Cloudflare R2** has historically needed extra configuration because it doesn't implement `GetBucketLocation`. If you pick R2, verify `restic init` and one full backup/restore cycle before relying on it.
- **Object Lock and pruning are in tension anywhere.** A locked file can't be deleted, so `forget --prune` fails inside the retention window — and on B2, enabling Object Lock on a bucket is irreversible. Leave it off unless you've deliberately made the retention period shorter than the prune interval.

**Composing a full backup story.** `offsite_backup` is one leg of three, each independently useful and independently removable:

- `postgres_dump` writes timestamped database dumps into a directory (it needs no setup and so has no section here).
- A `syncthing` folder replicates that directory to your other machines — the server dies, two live copies remain. Give the folder `type = "receiveonly"` on the machines that don't own it, so a deletion on a replica can't propagate back to the original.
- `offsite_backup` copies the same directory off-fleet — every machine gone, still recoverable.

None of the three knows about the others; they meet because your blueprint points them at the same path.

### Restoring

Restoring overwrites a live database, so machinekit has no `restore` command — it's a deliberate act you perform yourself. Two tiers, depending on how much is gone.

**From a dump file you still have** (on the server, or on any machine the sync mesh reached). Restore into a *new* database first, check it, and only then swap — never straight over the live one:

```bash
createdb -U postgres hindsight_restored
pg_restore -U postgres -d hindsight_restored --no-owner <the .dump file>
psql -U postgres -d hindsight_restored -c 'SELECT count(*) FROM memory_units'
```

`pg_restore` ships with PostgreSQL, so the custom-format dump needs no extra tooling; any extension the database uses (e.g. `vector`) must be installed on the target, which is what `machinekit apply` already does for a `hindsight_server` machine.

**From the offsite repository**, when no dump file survives. Pull the file out first, then restore it exactly as above:

```bash
export RESTIC_REPOSITORY='<your repository string>'
export RESTIC_PASSWORD_FILE=<the repository password, from your secrets manager>
# plus the backend's own credential variables
restic snapshots                       # pick the one you want
restic restore <snapshot-id> --target /tmp/restored
```

On a bare machine you need three things to get here: the restic binary (a single static download), the repository password, and the backend credentials. The password is the one that can't be reconstructed — it lives in your secrets manager like every other secret, and losing it makes the offsite copy permanently unreadable.
