# machinekit

A dotfiles and provisioning framework that gets a Mac or Linux machine into a consistent dev state with one command. Pairs with a per-user **blueprints** repo that supplies your actual config.

machinekit takes a fresh machine from "nothing installed" to "working dev environment with sensible defaults." It's idempotent — re-running it is safe and picks up any drift or new packages you've added to your blueprints.

For how it works and the reasoning behind it, see [docs/architecture.md](./docs/architecture.md).
For what's planned and what's deferred, see [docs/roadmap.md](./docs/roadmap.md).
For modules that need one-time external setup (an account, a secret, a key to register — e.g. Tailscale), see [docs/modules.md](./docs/modules.md).

## What it does

- Installs Homebrew, then machinekit's prerequisites — `jq`, `toml2json`, and `git`, the tools it needs before it can read your blueprints.
- Runs the modules your blueprint activates in `machinekit.toml` (`modules = [...]`) — each installs its formulae and lays down its config. `gomplate` (the template renderer) is the only always-on module; everything else is opt-in. For example, the `brewfile` module installs your `common/Brewfile` (and `machine_types/<type>/Brewfile` additively when a machine type is set), and the `git`, `zsh`, `mise`, and `age` modules each set up their own tool and dotfiles.
- Builds a merged staging dir from module-shipped templates plus your blueprint's `common/home/` (and `machine_types/<type>/home/` when a machine type is set), then applies it to `$HOME`. As each file is applied, machinekit runs any content transforms its name calls for — `.tmpl` files are rendered, and `.age` files are decrypted when the age module is active. Existing files that differ get a per-file prompt in interactive mode (overwrite / skip / abort / diff, with bulk shortcuts); non-interactive mode obeys `--conflict-behavior` (default: `overwrite`).
- Runs post-apply module steps (e.g. `mise install`, which needs its config placed by home sync first), then any `common/hooks/post-apply/` and `machine_types/<type>/hooks/post-apply/` scripts you supply.

What lands on disk depends on which modules your blueprint activates and what its `common/home/` ships. The always-on baseline is small:

- Homebrew, plus the prerequisite tools (`jq`, `toml2json`, `git`), available in `PATH`.
- Whatever home files your blueprint's `common/home/` (and `machine_types/<type>/home/`) provides.

Each opt-in module adds its own outputs when you activate it — for example:

- **`zsh`** — `~/.zshrc` (sources `~/.config/machinekit/env.zsh` and, if present, `~/.zshrc.local`) and `~/.config/machinekit/env.zsh` (`brew shellenv`, `~/.local/bin` on `PATH`, history, completion; ends with a source loop over `~/.config/machinekit/env.zsh.d/*.zsh` so other modules can drop in zsh fragments).
- **`git`** — `~/.gitconfig` (your name/email, `init.defaultBranch = main`) and `~/.config/git/ignore` (seeded with common OS/editor artifacts like `.DS_Store`, `*.orig`, `.idea/`).
- **`mise`** — `~/.config/mise/config.toml` (empty by default; you add the runtimes you use) and a `mise` activation fragment under `env.zsh.d/`.

The starter blueprint (`machinekit generate`) ships a `~/.ssh/config` (mode 600; on macOS `UseKeychain yes`) in its `common/home/` and leaves every module commented out — so applying it untouched gives you the baseline plus that ssh config, and nothing more until you enable modules.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravigadad/machinekit/main/install.sh)"
```

This clones machinekit to `~/.local/share/machinekit/framework` (override with `MACHINEKIT_FRAMEWORK_DIR=/your/path`), installs a modern bash if the system one is too old, and links the `machinekit` command into `~/.local/bin` on your `PATH` — so you can run `machinekit` by name. Pass `--no-modify-path` to link the command but leave your shell rc untouched (it then prints how to add `~/.local/bin` to your `PATH` yourself). Re-running updates the existing clone in place.

Installing the tool does **not** apply a blueprint — that's a separate step (see [Quick start](#quick-start)).

## CLI structure

machinekit ships a single user-facing command, `machinekit`, that dispatches to subcommand-specific binaries:

| Command | What it does |
|---|---|
| `machinekit apply [flags]`     | Apply a blueprint to this machine (the workhorse) |
| `machinekit generate <path>`   | Scaffold a fresh blueprint repo from the template |
| `machinekit secrets list`      | List each secret the active modules need with its resolved source (pool, secrets manager, or missing); applies nothing, but readies an active secrets manager (which may authenticate) |
| `machinekit secrets put [<name>]` | Age-encrypt a value and place it as a pool secret, or file an already-encrypted `.age` as-is (value via stdin/file/prompt, never an argument); writes to a working tree, never git |

Run any subcommand with `--help` for its full flag list.

The [installer](#install) puts `machinekit` on your `PATH`, so you can run it by name. To run from a checkout while working on machinekit itself, see [Developing machinekit](#developing-machinekit).

## Quick start

After [installing](#install), scaffold a blueprint, customize it, and apply:

```bash
# 1. Scaffold a fresh blueprints repo at a path you choose
machinekit generate ~/code/my-blueprints

# 2. Customize the template at ~/code/my-blueprints, then commit it.
#    (machinekit apply reads from committed content; uncommitted edits are ignored.)
( cd ~/code/my-blueprints && git add -A && git commit -m 'initial' )

# 3. Preview what would change — no modifications made
machinekit apply --dry-run --blueprints-source file://$HOME/code/my-blueprints

# 4. Apply for real
machinekit apply --blueprints-source file://$HOME/code/my-blueprints
```

To set up another machine, push your blueprints repo to GitHub, [install machinekit](#install) there, and apply from the URL:

```bash
machinekit apply --blueprints-source https://github.com/<owner>/my-blueprints
```

If your blueprints repo is private (SSH URL), machinekit handles SSH key setup. Pass flags upfront (required for non-interactive / automation):

```bash
# Install an existing key (USB drive, AirDrop, NAS mount, etc.)
machinekit apply \
  --existing-ssh-key-file /Volumes/USB/id_ed25519 \
  --blueprints-source git@github.com:<owner>/my-blueprints

# Generate a fresh key — machinekit prints it and pauses so you can add it to GitHub/GitLab/etc.
machinekit apply \
  --generate-ssh-key \
  --blueprints-source git@github.com:<owner>/my-blueprints
```

Or skip the SSH flags entirely: in interactive mode, if the clone fails due to authentication, machinekit offers to install an existing key or generate a new one, then retries the clone automatically.

On a fresh machine, the first apply will prompt you to:

- Either point at an existing age private key (`--existing-age-key-file <path>` or env), or explicitly opt into generating a new one (`--generate-age-key`).
- Provide your machine type — via flag, env var, or interactive prompt.
- Module-specific inputs (e.g. `git user.name` and `git user.email`) are read from your blueprint's `machinekit.toml` under `[module.git]`, or prompted if absent.

If your blueprints URL needs authentication (e.g. private HTTPS), configure git's credentials before running — machinekit uses git's existing auth (SSH key, `.netrc`, credential helper) rather than managing credentials itself.

Subsequent applies skip what's already done (Homebrew is installed, the age key exists).

## Invocation modes

`machinekit apply` runs in one of two modes.

**Interactive** — the default when stdin is a TTY. Inputs are resolved CLI flag → env var → [per-user defaults file](#per-user-defaults--xdg-directories) → interactive prompt for whatever is missing. Force interactive with `--interactive` if stdin isn't a TTY but `/dev/tty` is readable.

```bash
machinekit apply                                                  # prompts for everything
machinekit apply --blueprints-source https://github.com/me/blueprints  # prompts only for what's missing
```

The blueprint source can be a git repo (cloned) or a local directory (copied as-is — useful while iterating on a working tree before committing). One flag covers both:

- `--blueprints-source <url-or-path>` (`MACHINEKIT_BLUEPRINTS_SOURCE`): the protocol is sniffed automatically. A URL (`https://`, `http://`, `ssh://`, `git@host:owner/repo`, `file://`) or a local path containing `.git/` is cloned via `git clone`; a plain local path is copied as-is, skipping git entirely.
- `--blueprints-source-protocol <git|cp>` (`MACHINEKIT_BLUEPRINTS_SOURCE_PROTOCOL`): override the sniffed protocol — e.g. force `cp` to copy a local git repo's working tree (uncommitted edits included) instead of cloning its committed state.

**Non-interactive** — auto-detected when stdin isn't a TTY (cron, CI, curl-piped, redirected stdin), or forced with `--non-interactive` / `MACHINEKIT_MODE_INTERACTIVE=0`. Inputs are resolved CLI flag → env var → [per-user defaults file](#per-user-defaults--xdg-directories) → hard-fail.

Prerequisites to set up before a non-interactive run:

- **sudo without prompting**, via passwordless sudo (entry in `/etc/sudoers.d/`) or a pre-warmed credential cache (`sudo -v` within the previous ~5 minutes). machinekit's preflight checks this and hard-fails fast if neither is available.
- **Git authentication** for the blueprints clone (SSH key, `.netrc`, credential helper). machinekit doesn't manage credentials — git's existing auth is used as-is. Not needed when the source is a plain local path copied via `cp` (no git involvement).

Inputs can come from CLI flags, env vars, or any mix:

```bash
# Easiest single recipe: pre-warm sudo, then run with all env vars
sudo -v && \
MACHINEKIT_MODE_INTERACTIVE=0 \
MACHINEKIT_BLUEPRINTS_SOURCE=https://github.com/me/blueprints \
MACHINEKIT_MACHINE_TYPE=dev \
MACHINEKIT_EXISTING_AGE_KEY_FILE=/path/to/age.key \
  machinekit apply

# All CLI flags
sudo -v && machinekit apply --non-interactive \
  --blueprints-source https://github.com/me/blueprints \
  --machine-type dev \
  --existing-age-key-file /path/to/age.key

# Mixed — env vars + CLI flags
sudo -v && \
MACHINEKIT_EXISTING_AGE_KEY_FILE=/path/to/age.key \
  machinekit apply --non-interactive \
    --blueprints-source https://github.com/me/blueprints \
    --machine-type dev
```

Run `machinekit apply --help` for the full flag list.

## Per-user defaults & XDG directories

Inputs you'd otherwise re-pass on every apply can live in a per-user defaults file at `${XDG_CONFIG_HOME:-~/.config}/machinekit/defaults.toml`. It's consulted in the resolution cascade between env vars and prompting/erroring — a flag or env var still wins; the file only fills in what you didn't provide. Its keys mirror the input names:

```toml
machine_type = "dev"
blueprints.source = "https://github.com/me/blueprints"

[ssh]
key_generate = true
```

machinekit honors the [XDG base-directory](https://specification.freedesktop.org/basedir-spec/latest/) variables throughout: its config lives under `${XDG_CONFIG_HOME:-~/.config}/machinekit/` and its own data (the cached blueprint source, the install clone) under `${XDG_DATA_HOME:-~/.local/share}/machinekit/`. It also respects them when placing config for tools that read them — e.g. the `git` and `mise` module dotfiles land under `$XDG_CONFIG_HOME` when you've set it. The `~/.config` and `~/.local/share` paths shown elsewhere in this README are the defaults when those variables aren't set.

## Developing machinekit

To work on machinekit itself, clone the repo and run it from the checkout — `bin/machinekit` is the entry point, so no install step is needed:

```bash
git clone https://github.com/ravigadad/machinekit.git
cd machinekit
bin/machinekit apply --help
```

Run the test suite with `scripts/test` and the linter with `scripts/lint`.

## Repo layout

```
machinekit/
├── bin/
│   └── machinekit                # the one public entry: dispatcher that resolves a modern bash and runs the impl
├── libexec/                      # internal impls (not on PATH), run under the resolved bash
│   ├── machinekit-apply          # apply a blueprint
│   ├── machinekit-generate       # scaffold a fresh blueprint
│   ├── machinekit-secrets        # inspect the secrets pool (read-only)
│   └── machinekit-ensure-on-path # installer helper: link the command into ~/.local/bin + onto PATH
├── lib/                          # execution code (bin/ is a thin dispatcher)
│   ├── machinekit.sh             # aggregator: sources all of lib/machinekit/* eagerly
│   ├── machinekit/               # core: helpers, blueprints, brew bootstrap, preflight, hooks, module orchestration
│   └── modules/                  # built-in modules, lazy-sourced via modules::source_all
│       ├── git/templates/        # module-shipped defaults (dot_gitconfig.tmpl, xdg_config/git/ignore.tmpl)
│       ├── mise/templates/       # module-shipped defaults (xdg_config/mise/…, env.zsh.d/mise.zsh)
│       └── zsh/templates/        # framework zsh dotfiles (dot_zshrc, env.zsh w/ env.zsh.d loop)
├── scripts/                      # dev/maintainer tools (e.g. lint)
├── tests/                        # bats test suite mirroring lib/ and bin/
└── templates/blueprints/         # starter content copied into your blueprints repo
    ├── common/
    │   ├── machinekit.toml       # floor of the config cascade
    │   ├── Brewfile
    │   ├── home/                 # blueprint-owned home files (module default dotfiles ship with the modules, not here)
    │   │   ├── .mkignore         # destination paths to skip when applying home
    │   │   └── private_dot_ssh/private_config.tmpl   # → ~/.ssh/config
    │   └── hooks/post-apply/
    └── machine_types/
        └── README.md
```

Your blueprints repo lives separately (anywhere you like), scaffolded by `machinekit generate` and evolved independently.

## Platform support

macOS (Apple Silicon and Intel) and Linux (Ubuntu and compatible). machinekit is designed to support both and will continue to be — the CI suite includes end-to-end tests on Ubuntu VMs. Primary development happens on macOS, so Linux incompatibilities may be caught less quickly, but cross-platform compatibility is a project goal. See [docs/architecture.md#cross-platform-posture](./docs/architecture.md#cross-platform-posture) for the approach.

## Acknowledgements

machinekit composes existing tools rather than reinventing them:

- [Homebrew](https://brew.sh/) — package manager for macOS and Linux; machinekit's install mechanism.
- [gomplate](https://docs.gomplate.ca/) — Go/Sprig template engine for dotfiles.
- [mise](https://mise.jdx.dev/) — runtime version manager; available as a built-in module.
- [age](https://age-encryption.org/) — encryption tool; available as a built-in module for managing blueprint secrets.

## Contributing

Bug reports and feature ideas are welcome via [GitHub issues](https://github.com/ravigadad/machinekit/issues). For structural changes, read [docs/architecture.md](./docs/architecture.md) first.

## Security

Report vulnerabilities via GitHub's [private vulnerability reporting](https://github.com/ravigadad/machinekit/security/advisories/new) rather than opening a public issue.

## License

[MIT](./LICENSE).
