# machinekit architecture

This document describes how machinekit works and the reasoning behind its structure. Parts not yet built carry a `Status: not yet implemented` flag that flips when the work lands; the surrounding text doesn't need to change.

For current capabilities and quick start, see the [README](../README.md). For what's done, what's next, and what's deferred, see [roadmap.md](./roadmap.md).

---

## The two pieces

machinekit is two cooperating repos:

1. **machinekit** (this repo, public) — the framework: `machinekit apply`, helpers, modules, blueprints template, scaffolding script. No personal config, no secrets.
2. **blueprints** (your repo, private) — your config: Brewfile choices, dotfile templates, encrypted secrets, module declarations. Created from the template, evolves independently.

`machinekit apply` is the entry point. Given a blueprints repo, it provisions a fresh machine end-to-end. It's idempotent — re-running upgrades any drift but never breaks a working state.

## Scope

macOS and Linux, by design (see [cross-platform posture](#cross-platform-posture)). machinekit is opinionated about a deliberately small stock toolset — Homebrew and the handful of CLI helpers it bootstraps with — and agnostic about everything else. You extend it two ways: declare a machinekit-known module in TOML (Tier 2), or wire up anything at all via post-apply hooks (Tier 3). The fact that machinekit isn't opinionated about a tool doesn't mean you can't use machinekit to install and manage it — you can, via hooks. The small built-in set is just what machinekit has opinions about, not the limit of what it can do.

---

## Architecture

### Glossary

The same vocabulary applies across the code, docs, and user-facing language. Worth nailing down:

- **blueprints** (plural) — the whole collection. The repo. Your `machinekit-blueprints/`. "My blueprints."
- **a blueprint** (singular) — one machine type's full design: the assembled result of `common/` content + that machine type's `machine_types/<type>/` overrides. "Apply the personal blueprint."
- **common layer** — the shared baseline that every blueprint inherits. Lives at `common/` in the blueprints repo. Not a blueprint by itself.
- **machine type** — a label/key that names a blueprint, passed via `--machine-type <name>` or `MACHINEKIT_MACHINE_TYPE`. The directory `machine_types/<name>/` holds that type's overrides on top of `common/`.
- **module** — a unit of orchestration logic (install + configure + integrate). Modules are named in `machinekit.toml`; they declare dependencies via `::requires` and machinekit resolves the install order automatically. Some modules are **capabilities** — abstract slots resolved to a concrete **satisfier** (see below). A small set are **base modules** — framework-owned and always active regardless of what a blueprint requests.
- **capability** — an abstract slot that modules declare they need or provide. Lets multiple modules satisfy the same need (e.g. `container_manager` is satisfied by `orbstack` on macOS, `docker_ce` on Linux). Resolved by machinekit with per-platform defaults; the user overrides by listing a specific satisfier explicitly.

### Two repos

**machinekit** (public): the framework. The `machinekit` CLI (with `apply` and `generate` subcommands), the `lib/` helpers, and the blueprints template. No personal config, no secrets.

**blueprints** (private, per user): your config. Brewfile choices, dotfile templates, encrypted secrets, module declarations (TOML).

The blueprints template lives inside machinekit at `templates/blueprints/` rather than as a separate GitHub Template Repository. The `machinekit generate <path>` command copies the template into the path you give it. Users initialize and publish the resulting repo to whichever git host they prefer (GitHub, GitLab, SourceHut, self-hosted, etc.). Keeping the template inside machinekit keeps it in lockstep with the framework, with no third repo to drift.

### Blueprint structure

A blueprints repo has this layout:

```
blueprints/
├── common/
│   ├── machinekit.toml              # shared module config (floor of the cascade)
│   ├── Brewfile                     # packages installed on every machine
│   ├── home/                        # files copied to $HOME
│   │   ├── .mkignore
│   │   ├── dot_zshrc
│   │   └── …                        # only what the blueprint owns; module
│   │                                # templates (gitconfig, mise, etc.) ship
│   │                                # inside the modules themselves
│   └── hooks/
│       └── post-apply/              # shell scripts run after dotfiles + Brewfile
└── machine_types/
    ├── personal/
    │   ├── machinekit.toml          # personal-specific config overrides
    │   ├── home/                    # overlay on top of common/home/
    │   ├── Brewfile                 # additional packages just for personal
    │   └── hooks/post-apply/
    └── server/
        └── …
```

The structure is **layered**: `common/` is the baseline applied to every machine, and `machine_types/<type>/` is opt-in per-type overrides. The same shape — `machinekit.toml`, `home/`, `Brewfile`, `hooks/post-apply/` — appears at both levels.

Modules can ship their own default dotfile templates (e.g. the git module ships `dot_gitconfig.tmpl`, the mise module ships `dot_config/mise/config.toml`). At apply time, machinekit composes a single staging dir by layering: each active module's bundled templates first, then `common/home/` on top, then `machine_types/<type>/home/` on top of that. A user overrides a module's default by placing a file at the same relative path in their blueprint's home directory. See [home template system](#home-template-system) for details.

At apply time, with `--machine-type <type>`:

1. **home** — module template dirs layer first; then `common/home/`; then `machine_types/<type>/home/`. machinekit applies the merged result.
2. **Brewfile** — `common/Brewfile` runs first; then `machine_types/<type>/Brewfile` (additive).
3. **hooks/post-apply/** — `common/`'s hooks run first; then the type's hooks.
4. **machinekit.toml** — `common/machinekit.toml` is loaded; values in `machine_types/<type>/machinekit.toml` override on key conflict.

Without `--machine-type`, only the `common/` layer applies. There is no special "default" machine type; absence of the flag means "no type-specific layering."

The filesystem is doing the work TOML couldn't do cleanly: each file is flat and easy to read, and the hierarchy lives in directories instead of in deeply-nested TOML sections.

### Three-tier customization

machinekit is opinionated by default and configurable when you want more. Customization falls into three tiers, from least to most invasive:

**Tier 1 — Stock blueprint (zero config).** Generate a fresh blueprint, commit nothing more, and you get a working machine: Homebrew, git, and minimal sensible dotfiles. Nothing optional. This is the path for someone who just wants a sane laptop.

**Tier 2 — Config-driven (TOML).** A `common/machinekit.toml` (and per-type `machine_types/<type>/machinekit.toml`) declares which machinekit-known modules you want and supplies their variables:

```toml
# machine_types/personal/machinekit.toml
modules = ["tool_version_manager", "container_manager"]
```

machinekit knows every supported module, its capability dependencies, and its config schema. Opting into a capability (`tool_version_manager`, `container_manager`) automatically pulls in the platform's default satisfier — no need to spell out the concrete tool. Users can override by listing a specific satisfier explicitly. Most real-world configs live here.

> Status: implemented. `modules = [...]` in `machinekit.toml` drives `preflight::resolve_active_modules`. Capability modules and satisfier modules are both live.

**Tier 3 — Hooks (imperative escape hatch).** For tools machinekit doesn't know about, blueprints can drop shell scripts into lifecycle directories (`hooks/post-apply/`), and `machinekit apply` runs them in alphabetical order at the named phase. The intended graduation path: a hook prototypes a new tool; if it's broadly useful, it gets proposed upstream as a machinekit module; once accepted, the user's blueprint deletes the hook and replaces it with a few config lines in Tier 2.

> Status: `common/hooks/post-apply/` is read by `machinekit apply` from iteration 1. Tier-2 graduation begins in iteration 3.

### The minimal-spec principle

Alongside the explicit-consent rule (below), machinekit follows a strong **minimal-spec principle**: a blueprint should declare only what makes it unique. Sensible defaults handle everything else.

In practice:

- An empty `machinekit.toml`, an empty `Brewfile`, an empty `dotfiles/` directory, and no `hooks/` should all be valid and produce a working machine.
- Modules declare their own dependencies (via capabilities); users don't list transitive dependencies.
- Cross-platform implementation choices have sensible defaults per platform (e.g. `container_manager` defaults to OrbStack on macOS, Docker Engine on Linux). Users only override when they have a specific reason.
- "Listing a satisfier in `modules = [...]`" *is* the override mechanism — no separate flag, no special syntax. The blueprint stays declarative.

The principle exists because the alternative (everything must be spelled out) makes blueprints brittle, verbose, and full of repeated knowledge that machinekit already has.

### Modules, capabilities, and satisfiers

There are two kinds of modules in machinekit's module system:

- **Regular modules** install and configure specific tools (`mise`, `orbstack`, `docker_ce`, `git`, `age`, etc.). Satisfier modules are regular modules that additionally declare `::provides` to advertise which capability they fulfill.
- **Capability modules** (`lib/modules/capabilities/`) are abstract slots. Each declares a default satisfier (platform-aware where needed) and delegates `::requires` to it. Their `::install` is a no-op — the satisfier does the real work.

**Capabilities** are the two implemented abstract slots: `tool_version_manager` (satisfied by `mise` by default) and `container_manager` (satisfied by `orbstack` on macOS, `docker_ce` on Linux). Users list a capability in `modules = [...]` and the resolver substitutes the default satisfier. Listing a concrete satisfier explicitly overrides the default — that's how someone says "use Docker, not OrbStack." If two satisfiers for the same capability end up in the active set, the resolver hard-fails unless `allow_multiple_satisfiers = true` is set.

> Status: implemented. `::install`, `::preflight`, `::requires`, and `::provides` conventions are live. `lib/modules/capabilities/` holds `tool_version_manager` and `container_manager`. `resolver.sh` handles topological sort, capability → default-satisfier substitution, and post-resolution conflict detection.

### Base modules

A small set of modules are **framework-owned and always active**, independent of what a blueprint requests — they provide machinery the framework itself depends on. The set is static (`MK_BASE_MODULES` in `lib/machinekit/modules.sh`); `preflight::resolve_active_modules` folds it into every run's active set as `base ∪ requested`. Modules don't self-declare base-ness — the framework decides, keeping the concern in one place.

gomplate is the motivating example. Template rendering is core, so the `.tmpl` content transform must always be available — but gomplate is otherwise an ordinary module (it installs via brew, ships a `file_transforms` handler, manages its own context). Making it a base module rather than a hardcoded prerequisite means it installs through the normal module pipeline and lives behind the same transform contract every other handler uses, instead of being special-cased in core.

> Status: implemented. `MK_BASE_MODULES=(gomplate)`; the active set is therefore never empty.

### Execution modes

Bootstrap supports two modes, detected automatically and overridable by flag:

1. **Interactive** — the default when stdin is a TTY. Inputs are resolved CLI flag → env var → interactive prompt for whatever is missing. Suits a fresh-laptop walkthrough and power users alike: provide what you already know, get prompted for the rest.
2. **Non-interactive** — no synchronous user input. Inputs are resolved CLI flag → env var → hard error with a clear list of what's missing. This is the mode for CI, mass-provisioning, and automation.

Detection: if stdin is a TTY and `--non-interactive` isn't set, the mode is interactive; otherwise non-interactive. The `--non-interactive` (or `MACHINEKIT_MODE_INTERACTIVE=0`) and `--interactive` flags override detection and are mutually exclusive.

**Sudo prerequisite.** `machinekit apply` requires sudo to be available — for the initial Homebrew install on a fresh machine, and for any future module operation that needs root. Preflight probes with `sudo -n -v`: if sudo is already available (passwordless sudo or a fresh credential cache), the run proceeds silently. In interactive mode, an unavailable sudo triggers `sudo -v` to prompt up front, avoiding mid-pipeline interruption. In non-interactive mode, an unavailable sudo is a hard preflight failure with a recipe (`sudo -v && bin/machinekit apply ...`). This matches how every other non-root provisioning tool (Ansible, Homebrew CI installs, etc.) handles non-interactive sudo — there's no documented escape hatch and machinekit doesn't try to invent one. `machinekit generate` doesn't need sudo; this requirement is specific to `apply`.

Once preflight verifies sudo, machinekit forks a background keep-alive that re-validates sudo every 60 seconds, keeping the credential cache warm for runs longer than sudo's default 5-minute `timestamp_timeout`. The keep-alive process is reaped via an EXIT trap when the script ends (clean, errored, or signaled). This is the same pattern Homebrew's own installer uses, and it removes "did we exceed the 5-minute cache window?" as a source of nondeterministic failure as iterations grow.

### The explicit-consent rule

machinekit never takes an irreversible or externally-visible action without explicit consent. "Consent" means either a CLI flag or env var was set (in non-interactive mode) or the user said yes to a prompt (in interactive mode).

Actions that require consent:

- Generating a new age private key (a new key can't decrypt files encrypted by a previous one — silent generation could lock a user out of their own blueprints).
- Running an OAuth login flow (opens a browser, modifies system auth state).
- Creating or pushing to a remote repository.
- Any future action that touches external state.

Local idempotent installs (`brew install`, `mise install`) do *not* require consent — they're safe to repeat and have no surprising side effects.

When consent is required and absent, machinekit exits with a clear error explaining what was attempted, where we looked for the input, and exactly how to provide it.

### Input resolution

Every required input passes through the same resolution chain:

1. CLI flag (e.g. `--blueprints-source`)
2. Environment variable (e.g. `MACHINEKIT_BLUEPRINTS_SOURCE`)
3. Config file (`~/.config/machinekit/bootstrap.toml`) — *not yet implemented*
4. Secrets manager reference (`op://...`) — *not yet implemented*
5. Interactive prompt — only if TTY and not `--non-interactive`
6. Hard error listing what's missing

One resolver handles all three execution modes without branching logic. New input sources (config files, secrets refs) add one case to the resolver; nothing else changes.

Env var convention: `MACHINEKIT_` prefix, full descriptive name, no abbreviations — `MACHINEKIT_BLUEPRINTS_SOURCE`, not `MK_BLUEPRINTS_SRC`. There's no length limit on env var names that matters in practice, and clarity beats brevity in shell.

---

## Cross-platform posture

machinekit is designed to support macOS and Linux, and will continue to be. Primary development happens on macOS (Apple Silicon and Intel), and the CI suite includes end-to-end tests on Ubuntu VMs. Choices that would lock the framework to a single OS are explicitly avoided; per-OS branch points are flagged from day one. Broadening Linux support is incremental work, not a redesign.

### Already cross-platform

- **Homebrew** is a [first-class Linux target](https://docs.brew.sh/Homebrew-on-Linux). Same `brew` CLI, same Brewfile concept. The install prefix varies (`/opt/homebrew`, `/usr/local`, `/home/linuxbrew/.linuxbrew`), but `brew shellenv` handles PATH uniformly across all three. Picking Homebrew is a unifying choice across mac and Linux, not a macOS lock-in.
- **Framework prerequisites** (see `prerequisites.sh`), the always-on base modules (gomplate), and machinekit's built-in modules (mise, age, …) are all cross-platform binaries available via Homebrew on either OS.
- **The conceptual architecture** — bootstrap, three tiers, modules, hooks, input resolution, execution modes, consent rule — is all shell-level and portable.

### Branch points

| Concern | macOS | Linux |
|---|---|---|
| Brew install prefix | `/opt/homebrew` or `/usr/local` | `/home/linuxbrew/.linuxbrew` |
| Shell PATH setup | `eval "$(brew shellenv)"` | same |
| SSH config `UseKeychain` | Yes | Omit (no Keychain) |
| Container runtime | OrbStack (free, fast on Apple Silicon) | Native Docker Engine |
| GUI app installs (Brewfile casks) | Supported | Most casks N/A |

### Rules for staying portable

- Templates gate any OS-specific content behind `{{ if eq .os.family "darwin" }}`. The cost is negligible and it avoids retrofits.
- Scripts and templates use `brew shellenv` for PATH setup and `brew --prefix` for ad-hoc lookups. Never hardcode prefix paths.
- When a module depends on something with no cross-platform option (e.g. OrbStack), the dependency is framed as the *capability* (a container runtime) and platform-specific modules satisfy it. The resolver picks the right concrete module based on OS.

---

## `machinekit apply` design

### Idempotent

Inspired by [thoughtbot/laptop](https://github.com/thoughtbot/laptop). Safe to run multiple times: every step checks state before acting, and re-running on a configured machine upgrades drift without breaking what's working.

### Blueprints clone authentication

machinekit splits authentication into two distinct concerns:

**SSH key setup** is machinekit's responsibility when cloning over SSH. Two paths:

- *Proactive* — if `--existing-ssh-key-file` or `--generate-ssh-key` is passed, machinekit installs or generates the key before the first clone attempt.
- *Reactive* (interactive mode only) — if the clone fails with an SSH authentication error and no key flags were given, machinekit offers to install an existing key from a path you provide or generate a fresh one, then retries the clone automatically. After generation, machinekit prints the public key and pauses so you can add it to your git provider.

**HTTPS and other credentials** remain git's responsibility. machinekit does not install or wrap host-specific auth tooling, and does not manage credential helpers, `.netrc`, or access tokens. The contract: whatever method git already uses to authenticate to your URL, machinekit relies on that. That covers the full universe — credential helpers (`osxkeychain`, `libsecret`), `.netrc`, per-URL `http.extraHeader` tokens, any host's CLI that wires into git's credential helper.

**Clone error classification** — when the clone fails, machinekit inspects git's stderr and gives targeted output:

- SSH authentication failure → offer key setup (interactive) or suggest flags (non-interactive)
- HTTPS authentication failure → suggest configuring git credentials
- Network unreachable → connectivity check hint
- Repository not found → direct message (HTTPS caveat: private repos and missing repos are indistinguishable)

Keeping HTTPS credential handling out of machinekit's scope preserves host-agnostic posture (no preference for GitHub over GitLab, SourceHut, Codeberg, self-hosted Forgejo, etc.) and avoids reimplementing what git already does well. For headless SSH setups, pre-provide `--existing-ssh-key-file` or `--generate-ssh-key`. For HTTPS headless, credentials must be provisioned before machinekit runs (cloud-init, pre-baked image, secrets-manager wrapper script).

### Age key handling

age is the encryption layer for sensitive blueprint files. Unlike SSH keys, the age key is **per-user, not per-machine** — every machine needs the same private key to decrypt files committed to the blueprints repo.

The flow:

1. Use `--existing-age-key-file <path>` if provided; copy that file to `~/.config/age/key.txt` with mode 600.
2. Otherwise use an existing key at `~/.config/age/key.txt` if present.
3. Otherwise, if `--generate-age-key` is set (or the user explicitly consents to a prompt in interactive mode), generate a new key with `age-keygen`, display the public key, and print a prominent BACK-UP-YOUR-PRIVATE-KEY warning.
4. Otherwise, hard-fail with a clear error explaining the three options.

Steps 3 and 4 exist because a new key cannot decrypt files encrypted by a previous one. If a user has an existing key but forgot to copy it, silently generating a new one would lock them out of their own encrypted blueprints. Generation always requires explicit consent.

---

## Secrets and key management

There is one root secret: the age private key. SSH keys are managed by machinekit's SSH module during bootstrap — installed from an existing file (`--existing-ssh-key-file`) or generated fresh (`--generate-ssh-key`) — and registered with whichever git host the user uses (via that host's normal SSH-key-add flow, which machinekit walks through interactively after generation). HTTPS credentials for the blueprints clone remain outside machinekit's scope; the user provides them via standard git mechanisms (`.netrc`, credential helper) before running.

Eventually, a 1Password CLI (or other secrets-manager) wrapper can fetch the age key from a vault and pass the path to bootstrap. This is purely a UX layer; bootstrap itself never depends on a specific secrets manager.

> Status: secrets-manager wrapper not yet implemented.

age-encrypted files can be committed to the blueprints repo and are decrypted **during home sync** by the content-transform pipeline — not by a separate post-sync pass over `$HOME`. The age module claims the `.age` extension as a decode-tier transform, so `secret.age` in a home layer is decrypted to its final content at `~/secret` as the file is applied. Decryption happening inside the pipeline (rather than after a verbatim copy) is what keeps reconcile and `--dry-run` operating on plaintext and never leaves ciphertext on disk. With the age module inactive the marker isn't registered and `secret.age` copies over as-is — unreadable but not an error. See [home template system](#home-template-system) for the pipeline and its cross-tier ordering rules.

> Status: implemented. The age module manages the key and supplies the `.age` decode handler; the [home transform pipeline](#home-template-system) runs it.

---

## File ownership conventions

Files that end up in `$HOME` after a bootstrap run fall into two categories:

- **Tool artifacts** — the age key at `~/.config/age/key.txt`, mise's runtimes, and so on. machinekit sets these up but doesn't own them. They live in the tool's own XDG-style directory so any future consumer of that tool can find them where it expects.
- **machinekit's own state** — files that exist *because* machinekit exists: the cached blueprint source at `~/.local/share/machinekit/blueprints/`, a future per-user bootstrap config (e.g. `~/.config/machinekit/bootstrap.toml`). These live in machinekit's XDG dirs (`~/.local/share/machinekit/` for data, `~/.config/machinekit/` for config).

> Status: nothing in `~/.config/machinekit/` yet. The directory is created on first use by a feature that needs it, not preemptively.

When adding new files, ask: tool artifact, or machinekit's own state? Former → the tool's XDG dir. Latter → `~/.config/machinekit/`.

---

## Machine types and layering

`machine_type` is an arbitrary label — provided to `machinekit apply` via `--machine-type` or `MACHINEKIT_MACHINE_TYPE`. The name itself carries no meaning to machinekit beyond serving as a directory key under `machine_types/`.

Each machine type's design is **composed** at apply time from two layers:

1. `common/` content — applied to every machine regardless of type.
2. `machine_types/<type>/` content — opt-in overrides specific to that type.

This composition happens uniformly across the four moving pieces of a blueprint:

- `home/` — machinekit applies `common/home/` first, then `machine_types/<type>/home/` on top. Same-target-path files in the type layer override the common layer.
- `Brewfile` — `common/Brewfile` runs first; `machine_types/<type>/Brewfile` runs after. Additive — both sets of packages get installed.
- `hooks/post-apply/` — common hooks run first, then type hooks. Both run.
- `machinekit.toml` — `common/machinekit.toml` is loaded; values in `machine_types/<type>/machinekit.toml` override on key conflict.

Without `--machine-type`, only the common layer applies. There is no implicit "default" type — the absence of a flag means "no type-specific layering." Users with a single-machine setup or a uniform fleet leave `machine_types/` empty (or omit the `--machine-type` flag) and have no need to think about layering at all.

Machine types are how blueprints *express variation* across a fleet. They're not a tagging system or a capability flag set — those concerns live in `[modules.*]` config (iteration 2/3) and in the modules' own capability declarations.

> Status: the directory structure ships in iteration 1. All four layers — `home/`, `Brewfile`, `hooks/post-apply/`, and `machinekit.toml` — are implemented (iteration 2). End-to-end validation with a non-default machine type is done.

---

## home template system

machinekit walks a merged staging dir and applies each file to `$HOME`. A staged filename encodes two **independent** things, resolved separately:

1. **Addressing** — what the file is called and how it's permissioned. A pure function of the *name*, encoded as path-component prefixes.
2. **Content representation** — what transforms the *bytes* need before they land. A function of the content, encoded as filename-suffix markers.

These axes commute (renaming a file doesn't change how its bytes are transformed; decrypting it doesn't change where it lands), which is why machinekit resolves them independently.

**Addressing (prefixes)** — each path component is decoded from the staging naming convention:

- `dot_` prefix → leading `.` (e.g. `dot_zshrc` → `.zshrc`)
- `private_` prefix → mode 600 on the file, mode 700 on the parent directory (e.g. `private_dot_ssh/private_config` → `~/.ssh/config` at 600, `~/.ssh/` at 700)

**Content representation (suffix markers)** — a trailing extension can name a content-pipeline stage. Each marker is registered by a module as `extension → (tier, handler)`:

- `.tmpl` (gomplate base module) → render the file as a template
- `.age` (age module) → decrypt the file

A marker is *consumed* — stripped from the destination name — when its stage runs: `dot_zshrc.tmpl` renders to `~/.zshrc`, `secret.age` decrypts to `~/secret`. An unregistered trailing extension is just part of the filename and kept as-is (`notes.md` → `~/notes.md`).

**Two tiers, one law.** Markers fall into two tiers by a single test — *can a later pass read this file without this transform having run?*

- **decode tier** (`.age`, future `.gz`) — no; the bytes are opaque until it runs (decrypt, decompress).
- **content tier** (`.tmpl`) — yes; it operates on already-readable content (templating).

The one hard rule (the **cross-tier law**): every decode stage runs before any content stage — you can't template bytes you can't yet read. On the filename, decode markers must therefore be the outermost (rightmost) contiguous group. machinekit validates this and fails clearly on an impossible order. So `secret.tmpl.age` is valid (decrypt, then template) but `secret.age.tmpl` is rejected. Order *among* decode markers is read straight off the suffix stack right-to-left — it's physically forced by how the file was produced, not a policy machinekit invents.

**Markers come from modules.** A module that handles an extension declares it with one hook and supplies a handler that reads a path and writes the transformed bytes to stdout:

```bash
age::file_transforms() { printf '%s\n' "age decode age::decrypt"; }  # "ext tier handler"
age::decrypt() { age --decrypt --identity "$KEY" "$1"; }             # IN_PATH → stdout
```

The registry is built and validated in **preflight** (before any install), scoped to *active* modules. Two consequences:

- An extension maps to exactly one handler. A conflicting re-claim (same extension, different handler) is a hard failure naming both — there's no coherent "decode these bytes two ways." (An identical re-claim is a harmless no-op.)
- A marker whose module is **inactive** is simply never registered, so the file copies through verbatim — fail-safe. With the age module off, `secret.age` lands as the literal file `~/secret.age` rather than erroring.

Because transforms run *inside* the sync pipeline — between reading the staged file and reconciling it against `$HOME` — `$HOME` only ever sees final content at the final path. Reconcile, conflict detection, and `--dry-run` diffing all operate on the transformed result, so idempotency and diffs are correct regardless of which transforms a file passes through. (This is also why module installs run *before* home sync: a transform's binary or key must be present when the pipeline fires.)

**Template rendering** — `.tmpl` files render through `gomplate` with the full machinekit context JSON as the root data source. gomplate is a framework-owned [base module](#base-modules) (always active) that prepares the context and supplies the `.tmpl` handler. Templates access context values as nested fields: `.git.user_name`, `.os.family`, `.machine_type`, etc.

**Ignore file** — `.mkignore` in the staging dir lists destination paths (relative to `$HOME`, *after* markers are stripped) to skip. The `.mkignore` file itself is always skipped. An ignored file is never decrypted or rendered — the skip is decided from its resolved destination *before* any handler runs.

**Conflict resolution** — when a staged file would overwrite an existing `$HOME` file whose content differs, machinekit prompts rather than silently clobbering. In interactive mode: a per-file menu with overwrite / skip / abort / diff options, plus bulk overwrite-all / skip-all shortcuts. In non-interactive mode, the behavior is controlled by `--conflict-behavior=<overwrite|skip|abort>` (`MACHINEKIT_CONFLICT_BEHAVIOR`), defaulting to `overwrite` (previous behavior). File-format-aware merging is explicitly out of scope — that belongs in post-apply hooks.

Everything *around* file application is machinekit's:

- **Source fetching** — machinekit clones (`git clone`) or copies (`cp -r`) blueprints into `~/.local/share/machinekit/blueprints` itself, depending on whether the source resolves to the `git` or `cp` protocol. The cached source is treated as ephemeral and re-fetched on every apply.
- **Staging-dir composition** — machinekit operates against a *merged* staging dir at `~/.local/share/machinekit/staging`, not the raw blueprint. The staging dir is wiped and rebuilt every run, layered in this order: each active module's `lib/modules/<name>/templates/`, then the blueprint's `common/home/`, then `machine_types/<type>/home/` (when `--machine-type` is set). Same-path files in a later layer overwrite earlier ones, so the blueprint owns final say. Sibling blueprint content (`common/Brewfile`, `common/hooks/`, `common/machinekit.toml`, `machine_types/`) never enters the staging dir. `.mkignore` is scoped to within-home exclusions.

One flag picks the blueprint source; the protocol is sniffed and overridable:

- `--blueprints-source <url-or-path>` resolves the source and sniffs the protocol: a URL form (`https://`, `http://`, `ssh://`, `git@host:owner/repo`, `file://`) or a local path containing `.git/` is cloned via `git clone`; any other local path is copied as-is. No `owner/repo` shorthand — full URLs only, host-agnostic.
- `--blueprints-source-protocol <git|cp>` overrides the sniffed protocol — e.g. force `cp` to copy a local git repo's working tree (uncommitted edits included) instead of cloning its committed state. This is the "iterate without committing" path during blueprint authoring.

Template data flows from `context::` (machinekit's jq-backed runtime data store) into gomplate's root context as a JSON object. Keys use **snake_case dotted notation** so they nest as nested objects and become nested fields in the template namespace. Examples: `.machine_type`, `.git.user_name`, `.age.key_path`, `.modules.active` (an array of active module names). Blueprint and module templates access them normally:

```
{{- if eq .machine_type "personal" }}
# personal-machine tooling
{{- end }}

{{- if has "mise" .modules.active }}
# mise is enabled
{{- end }}
```

---

## mise

Runtime version manager (replaces rbenv, nvm, gvm, etc.). Config-as-code via `.tool-versions` or `~/.config/mise/config.toml`.

When declared as an active module, mise is installed without any runtimes pinned. Users add what they need:

```toml
# ~/.config/mise/config.toml
[tools]
ruby   = "3.3"
node   = "lts"
python = "3.12"
```

A Python or Rust developer using machinekit gets no gratuitous Ruby/Node installs. Tier 2 module config can layer per-machine_type defaults later — e.g. "all `dev` machines get the user's preferred language stack."

---

## Brewfile design

**Never use `brew bundle dump`.** It captures transitive dependencies and makes the Brewfile unmaintainable; Brewfiles are crafted by hand, with each entry a deliberate decision.

There are two installation stages:

1. **Prerequisite stage** — `machinekit apply` installs the few CLI tools preflight needs before it can read a blueprint at all: `jq` (the `context::` store runs on it), `toml2json` (to parse `machinekit.toml`), and `git` (to clone). They're installed directly rather than as modules because they must exist before module resolution runs; the authoritative list is `_MK_PREREQUISITES` in `lib/machinekit/prerequisites.sh`. gomplate is **not** here — it moved to a [base module](#base-modules), since it's only needed once home sync renders templates, which is inside the module/apply stage. `mise`, `age`, and other tools are likewise installed by their modules, not as prerequisites.
2. **Module install stage** — `brew bundle --file <blueprints>/common/Brewfile` runs as part of `modules::run_installs`, before home files are applied. With `--machine-type <type>`, `<blueprints>/machine_types/<type>/Brewfile` (if present) runs after, additively layering on top.

The template ships with commented Brewfiles showing the conventions; your blueprints contain your real choices.

> Status: both `common/Brewfile` and per-machine-type `machine_types/<type>/Brewfile` layering are implemented.

---

## File structure reference

```
machinekit/                             ← this repo (public)
├── README.md
├── CLAUDE.md
├── docs/
│   ├── architecture.md                 ← this file
│   └── roadmap.md
├── bin/                                ← thin orchestrators
│   ├── machinekit                      ← user-facing dispatcher
│   ├── machinekit-apply                ← apply a blueprint
│   └── machinekit-generate             ← scaffold a fresh blueprint
├── lib/                                ← all execution code lives here
│   ├── machinekit.sh                   ← single aggregator: sources lib/machinekit/* eagerly
│   ├── machinekit/                     ← core machinekit code
│   │   ├── logging.sh                  ← logging::* (info, warn, error, success, step, attention, debug, dry_run, fail)
│   │   ├── lifecycle.sh                ← lifecycle::* (cleanup chain, lock, fail)
│   │   ├── sudo.sh                     ← sudo::* (credential probe + 60s keep-alive)
│   │   ├── input.sh                    ← input::* (mode detection, confirm, dry-run, command_exists)
│   │   ├── context.sh                  ← context::* (jq-backed runtime data store: set/get, arrays, json, seed_from_flags)
│   │   ├── system.sh                   ← system::detect — populates os.family + os.arch into context
│   │   ├── brew.sh                     ← brew::* (bootstrap, install_formula — low-level brew ops)
│   │   ├── blueprints.sh               ← blueprints::* (fetch, dir, protocol resolution, clone error classification)
│   │   ├── ssh.sh                      ← ssh::* (key install, generate, interactive discover)
│   │   ├── config.sh                   ← config::* (parse + merge machinekit.toml via toml2json; stored in context)
│   │   ├── resolver.sh                 ← resolver::resolve — DFS topological sort over ::requires declarations
│   │   ├── modules.sh                  ← modules::* (source_all, run_preflights, run_installs, run_post_apply); MK_BASE_MODULES
│   │   ├── home.sh                     ← home::* (sync, _apply — core home management); sources home/staging.sh, home/dry_run.sh, home/transforms.sh
│   │   ├── home/
│   │   │   ├── staging.sh              ← home::staging::* (build, dir, cleanup — staging dir construction)
│   │   │   ├── dry_run.sh              ← home::dry_run::* (show_diff — diff generation and display)
│   │   │   └── transforms.sh           ← home::transforms::* (content pipeline: register markers, resolve, execute)
│   │   ├── prerequisites.sh            ← prerequisites::* (jq/toml2json/git via brew — gomplate is a base module)
│   │   ├── preflight.sh                ← preflight::* (system detect, blueprints fetch, config load, module resolution)
│   │   ├── hooks.sh                    ← hooks::* (post-apply hook runner; common + machine_type layers)
│   │   ├── hook-support.sh             ← library blueprint hooks source via $MACHINEKIT_SUPPORT
│   │   └── postflight.sh               ← postflight::* (apply summary output)
│   └── modules/                        ← user-facing modules; each exposes ::install
│       ├── age.sh                      ← age::preflight + age::install + age::decrypt (the .age decode handler) + age::file_transforms
│       ├── brewfile.sh                 ← brewfile::install (common + machine_type Brewfile layers)
│       ├── docker_ce.sh                ← docker_ce::provides + docker_ce::install (Linux container runtime)
│       ├── git.sh                      ← git::preflight + git::install (no-op; ships templates)
│       ├── git/templates/              ← module-shipped dotfile defaults (dot_gitconfig.tmpl, dot_config/git/ignore.tmpl)
│       ├── gomplate.sh                 ← gomplate::file_transforms + render + install (base module: the .tmpl handler)
│       ├── mise.sh                     ← mise::requires + mise::provides + mise::install + mise::post_apply
│       ├── mise/templates/             ← module-shipped dotfile defaults (dot_config/mise/…, env.zsh.d/mise.zsh)
│       ├── orbstack.sh                 ← orbstack::provides + orbstack::install (macOS container runtime)
│       ├── zsh.sh                      ← zsh::install (installs zsh via brew; module ships templates)
│       ├── zsh/templates/              ← framework zsh dotfiles (dot_zshrc, env.zsh w/ env.zsh.d loop)
│       └── capabilities/               ← abstract capability modules; each exposes ::is_capability, ::default_satisfier
│           ├── container_manager.sh    ← platform-defaulting capability (orbstack on macOS, docker_ce on Linux)
│           └── tool_version_manager.sh ← satisfied by mise (default)
├── scripts/                            ← dev/maintainer tools (lint, test-vm)
├── tests/                              ← bats test suite mirroring lib/ and bin/
└── templates/blueprints/               ← starter content copied by `machinekit generate`
```

**Convention**: `bin/` files are thin orchestrators (flag parsing, mode detection, the apply pipeline as a sequence of namespaced calls). All execution code lives in `lib/`. `lib/<name>.sh` is the aggregator for `lib/<name>/*.sh`; each file's namespace matches its filename (`brew::*` in `brew.sh`, `age::*` in `age.sh`, etc.).

**Module API**: every file in `lib/modules/` exposes `<name>::install` as its main entry point. Modules that need to resolve user inputs before the apply pipeline runs also expose `<name>::preflight`. Modules that need to run after home files are applied expose `<name>::post_apply` — this runs after `home::sync` but before post-apply hooks, which is why `mise::post_apply` runs `mise install` (it needs `~/.config/mise/config.toml` placed by home sync). Modules with inter-module dependencies declare them via `<name>::requires` (returning one dependency name per line); `resolver.sh` sorts the active set into install order. Satisfier modules additionally declare `<name>::provides` (returning the capability name they satisfy); the resolver uses this for conflict detection. Modules that transform file content by extension declare `<name>::file_transforms` (emitting `extension tier handler` lines, `tier` ∈ {`decode`, `content`}); `home::transforms` registers these at preflight and runs the matching handlers during sync — see [home template system](#home-template-system). Modules may also ship a sibling directory `lib/modules/<name>/templates/` holding default dotfiles; `home::staging::build` picks these up automatically. Active modules are driven by `modules = [...]` in `machinekit.toml` (plus the always-active `MK_BASE_MODULES`), resolved at preflight time.

**Zsh hook pattern**: the `zsh` module ships `~/.config/machinekit/env.zsh`, which ends with a glob-source loop over `~/.config/machinekit/env.zsh.d/*.zsh`. Any module that needs to contribute zsh-level setup drops a single `.zsh` file in its own `templates/dot_config/machinekit/env.zsh.d/` directory — the staging-dir builder merges it in, the home module installs it, and env.zsh sources it on every zsh startup. When a module is inactive, no fragment ends up on disk and nothing is sourced. mise uses this pattern today (`templates/dot_config/machinekit/env.zsh.d/mise.zsh` for `eval "$(mise activate zsh)"`); future modules plug in the same way.

Blueprints repo (private, per user) lives as a sibling on disk and mirrors the template structure with real values:

```
my-blueprints/                                  ← your blueprints (private)
├── common/                                     ← applied to every machine
│   ├── machinekit.toml                         ← shared module config (floor of the cascade)
│   ├── Brewfile                                ← packages installed everywhere
│   ├── home/                                   ← only what your blueprint owns
│   │   ├── .mkignore                           ← within-home exclusions
│   │   ├── private_dot_ssh/private_config.tmpl ← → ~/.ssh/config (mode 600)
│   │   └── …                                   ← override module defaults by same-path
│   └── hooks/post-apply/
└── machine_types/                              ← per-type overrides (optional)
    └── personal/                               ← e.g. for `--machine-type personal`
        ├── machinekit.toml
        ├── home/                               ← overlays common/home/
        ├── Brewfile                            ← additional packages
        └── hooks/post-apply/
```

Module-shipped templates that go to `$HOME` (e.g. `~/.gitconfig`, `~/.config/mise/config.toml`) come from the module, not the blueprint. Drop a file at the same relative path in `common/home/` (or `machine_types/<type>/home/`) to override.

---

## References

- [thoughtbot/laptop](https://github.com/thoughtbot/laptop) — idempotency inspiration
- [gomplate](https://docs.gomplate.ca)
- [mise](https://mise.jdx.dev)
- [age encryption](https://github.com/FiloSottile/age)
- [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux)
