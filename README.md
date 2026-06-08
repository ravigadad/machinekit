# machinekit

A dotfiles and provisioning framework that gets a Mac or Linux machine into a consistent dev state with one command. Pairs with a per-user **blueprints** repo that supplies your actual config.

machinekit takes a fresh machine from "nothing installed" to "working dev environment with sensible defaults." It's idempotent — re-running it is safe and picks up any drift or new packages you've added to your blueprints.

For how it works and the reasoning behind it, see [docs/architecture.md](./docs/architecture.md).
For what's planned and what's deferred, see [docs/roadmap.md](./docs/roadmap.md).

## What it does

- Installs Homebrew, then jq, toml2json, gomplate, and git — machinekit's prerequisites.
- Builds a merged staging dir from module-shipped templates plus your blueprint's `common/home/` (and `machine_types/<type>/home/` when a machine type is set), then applies it to `$HOME`. Existing files that differ get a per-file prompt in interactive mode (overwrite / skip / abort / diff, with bulk shortcuts); non-interactive mode obeys `--conflict-behavior` (default: `overwrite`).
- Runs `common/Brewfile` from your blueprints (if present), then `machine_types/<type>/Brewfile` additively (if present), then `mise install`, then any `common/hooks/post-apply/` and `machine_types/<type>/hooks/post-apply/` scripts you supply.

What you get on disk after a successful run:

- The tools above, available in `PATH`.
- `~/.zshrc` — sources `~/.config/machinekit/env.zsh` and (if present) `~/.zshrc.local` (from the zsh module's template).
- `~/.config/machinekit/env.zsh` — `brew shellenv`, `~/.local/bin` PATH, history, completion. Ends with a source loop over `~/.config/machinekit/env.zsh.d/*.zsh` so modules can drop their own zsh fragments (mise activation ships there).
- `~/.gitconfig` — your name/email, `init.defaultBranch = main` (rendered from the git module's template).
- `~/.config/git/ignore` — global gitignore seeded with common OS and editor artifacts (`.DS_Store`, `Thumbs.db`, `*.orig`, `.idea/`, etc.).
- `~/.ssh/config` (mode 600) — sensible defaults; on macOS, `UseKeychain yes`.
- `~/.config/mise/config.toml` — empty by default; you add the runtimes you actually use.

Nothing else. Add whatever you want via your blueprints' `common/Brewfile`, your own `common/home/`, or post-apply hooks.

## CLI structure

machinekit ships a single user-facing command, `machinekit`, that dispatches to subcommand-specific binaries:

| Command | What it does |
|---|---|
| `machinekit apply [flags]`     | Apply a blueprint to this machine (the workhorse) |
| `machinekit generate <path>`   | Scaffold a fresh blueprint repo from the template |

Run any subcommand with `--help` for its full flag list.

You can invoke `machinekit` directly from a clone (`bin/machinekit …`) or add `bin/` to your `PATH` so the command is available globally:

```bash
# Add to ~/.zprofile (or ~/.zshrc) — adjust the path to wherever you cloned machinekit
echo 'export PATH="$HOME/code/machinekit/bin:$PATH"' >> ~/.zprofile
source ~/.zprofile
```

## Quick start

```bash
# 1. Clone machinekit
git clone https://github.com/ravigadad/machinekit.git ~/code/machinekit
cd ~/code/machinekit

# 2. Scaffold a fresh blueprints repo at a path you choose
bin/machinekit generate ~/code/my-blueprints

# 3. Customize the template at ~/code/my-blueprints, then commit it.
#    (machinekit apply reads from committed content; uncommitted edits are ignored.)
( cd ~/code/my-blueprints && git add -A && git commit -m 'initial' )

# 4. Preview what would change — no modifications made
bin/machinekit apply --dry-run --blueprints-source file://$HOME/code/my-blueprints

# 5. Apply for real
bin/machinekit apply --blueprints-source file://$HOME/code/my-blueprints
```

To use the same blueprints on another machine, push your blueprints repo to GitHub and run the one-liner installer:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravigadad/machinekit/main/install.sh)" -- \
  --blueprints-source https://github.com/<owner>/my-blueprints
```

This clones machinekit to `~/.local/share/machinekit/framework` and hands off to `machinekit apply` with any flags you pass. On subsequent runs it updates the clone first. Override the location with `MACHINEKIT_FRAMEWORK_DIR=/your/path`.

If your blueprints repo is private (SSH URL), machinekit handles SSH key setup. Pass flags upfront (required for non-interactive / automation):

```bash
# Install an existing key (USB drive, AirDrop, NAS mount, etc.)
/bin/bash -c "$(curl -fsSL .../install.sh)" -- \
  --existing-ssh-key-file /Volumes/USB/id_ed25519 \
  --blueprints-source git@github.com:<owner>/my-blueprints

# Generate a fresh key — machinekit prints it and pauses so you can add it to GitHub/GitLab/etc.
/bin/bash -c "$(curl -fsSL .../install.sh)" -- \
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

**Interactive** — the default when stdin is a TTY. Inputs are resolved CLI flag → env var → interactive prompt for whatever is missing. Force interactive with `--interactive` if stdin isn't a TTY but `/dev/tty` is readable.

```bash
bin/machinekit apply                                                  # prompts for everything
bin/machinekit apply --blueprints-source https://github.com/me/blueprints  # prompts only for what's missing
```

The blueprint source can be a git repo (cloned) or a local directory (copied as-is — useful while iterating on a working tree before committing). One flag covers both:

- `--blueprints-source <url-or-path>` (`MACHINEKIT_BLUEPRINTS_SOURCE`): the protocol is sniffed automatically. A URL (`https://`, `http://`, `ssh://`, `git@host:owner/repo`, `file://`) or a local path containing `.git/` is cloned via `git clone`; a plain local path is copied as-is, skipping git entirely.
- `--blueprints-source-protocol <git|cp>` (`MACHINEKIT_BLUEPRINTS_SOURCE_PROTOCOL`): override the sniffed protocol — e.g. force `cp` to copy a local git repo's working tree (uncommitted edits included) instead of cloning its committed state.

**Non-interactive** — auto-detected when stdin isn't a TTY (cron, CI, curl-piped, redirected stdin), or forced with `--non-interactive` / `MACHINEKIT_MODE_INTERACTIVE=0`. Inputs are resolved CLI flag → env var → hard-fail.

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
  bin/machinekit apply

# All CLI flags
sudo -v && bin/machinekit apply --non-interactive \
  --blueprints-source https://github.com/me/blueprints \
  --machine-type dev \
  --existing-age-key-file /path/to/age.key

# Mixed — env vars + CLI flags
sudo -v && \
MACHINEKIT_EXISTING_AGE_KEY_FILE=/path/to/age.key \
  bin/machinekit apply --non-interactive \
    --blueprints-source https://github.com/me/blueprints \
    --machine-type dev
```

Run `bin/machinekit apply --help` for the full flag list.

## Repo layout

```
machinekit/
├── bin/
│   ├── machinekit                # user-facing dispatcher
│   ├── machinekit-apply          # apply a blueprint
│   └── machinekit-generate       # scaffold a fresh blueprint
├── lib/                          # execution code (bin/ files are thin orchestrators)
│   ├── machinekit.sh             # aggregator for lib/machinekit/*
│   ├── modules.sh                # aggregator for lib/modules/*
│   ├── machinekit/               # core: helpers, blueprints, brew bootstrap, preflight, hooks, prerequisites
│   └── modules/                  # user-facing modules: age, brewfile, home, git, mise, zsh
│       ├── git/templates/        # module-shipped defaults (dot_gitconfig.tmpl, dot_config/git/ignore.tmpl)
│       ├── mise/templates/       # module-shipped defaults (dot_config/mise/…, env.zsh.d/mise.zsh)
│       └── zsh/templates/        # framework zsh dotfiles (dot_zshrc, env.zsh w/ env.zsh.d loop)
├── scripts/                      # dev/maintainer tools (e.g. lint)
├── tests/                        # bats test suite mirroring lib/ and bin/
└── templates/blueprints/         # starter content copied into your blueprints repo
    ├── common/
    │   ├── machinekit.toml       # floor of the config cascade
    │   ├── Brewfile
    │   ├── home/                 # only blueprint-owned files; module defaults
    │   │   ├── .mkignore         # ship with the modules, not here
    │   │   └── private_dot_ssh/private_config.tmpl
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
