# machinekit roadmap

The framework is built iteratively rather than in big-bang phases, so each layer can be exercised against a real machine before the next layer commits on top of it. Iterations are scope-boxed, not time-boxed. Each one ships user-facing value that later layers build on without breaking.

Architecture is described in [architecture.md](./architecture.md); this document covers what's done, what's next, and what's deliberately deferred.

---

## Iteration 1 — Stock laptop bootstrap

**Status: implemented.**

**Value**: a single command takes a fresh macOS machine from "nothing installed" to "working dev environment with sensible defaults," driven by the user's blueprints. No optional tools, no machine-type branching — just a clean baseline.

**Deliverables:**

- `machinekit apply` — main entry point. Two execution modes (interactive / non-interactive). Idempotent. Consent-gated for irreversible actions.
- `lib/machinekit/` + `lib/modules/` — execution code, split between core machinekit infrastructure (helpers, brew bootstrap, blueprints fetch, preflight orchestration, hooks, prerequisites) and user-facing modules (age, brewfile, git, mise, zsh). Aggregated by `lib/machinekit.sh` (eager); modules are lazy-sourced via `modules::source_all`. `bin/` files are thin orchestrators.
- `context::` — a jq-backed runtime data store, accessed via `context::set` / `context::get` (scalars) and `context::set_array` / `context::get_array` (arrays) using snake_case dotted keys. Passed to gomplate as the root context at apply time so blueprint dotfiles can reference values as nested template fields (`.git.user_name`, `.modules.active`, etc.).
- Module template bundling — modules can ship default dotfile templates in `lib/modules/<name>/templates/`. The git, mise, and zsh modules ship their own defaults (gitconfig, mise config, dot_zshrc + env.zsh). Users override per-path in their blueprint's `common/home/`.
- Zsh hook pattern — the `zsh` module's env.zsh ends with a glob-source loop over `~/.config/machinekit/env.zsh.d/*.zsh`. Modules that need zsh setup ship a fragment in their `templates/dot_config/machinekit/env.zsh.d/`. mise uses this today; future modules plug in the same way.
- Staging dir — built fresh each run at `~/.local/share/machinekit/staging` by layering module templates → blueprint `common/home/` → (iteration 2+) `machine_types/<type>/home/`. The template engine is invoked against the staging dir, not the raw blueprint.
- `machinekit generate` — scaffolds a fresh blueprint repo from the template at the path you give it.
- `templates/blueprints/` — starter content in the layered layout:
  - `common/machinekit.toml` — placeholder for shared module config (floor of the cascade; read by iteration 2/3; commented examples ship in iteration 1).
  - `common/home/` — content the blueprint owns directly (module-shipped templates live with the modules, not here):
    - `private_dot_ssh/private_config.tmpl` — sensible defaults; `UseKeychain yes` macOS-only.
    - `.mkignore` — small; only excludes things *within* the home tree (e.g. `.zshrc.local`).
  - `common/Brewfile` — empty, commented.
  - `common/hooks/post-apply/` — empty placeholder.
  - `machine_types/README.md` — placeholder explaining the per-type override layout for iteration 2.
- Home file application walks the staging dir, decodes chezmoi path conventions (dot_, private_, .tmpl), renders templates via gomplate with the full context JSON, and copies files to `$HOME` with appropriate permissions. machinekit owns the full pipeline — no external source manager. Conflict resolution: when a staged file differs from the existing `$HOME` file, interactive mode prompts per-file (overwrite / skip / abort / diff, with bulk variants); non-interactive mode obeys `--conflict-behavior` (`MACHINEKIT_CONFLICT_BEHAVIOR`), defaulting to `overwrite`.
- SSH module (`ssh.sh`) — installs an existing key or generates a fresh one before (proactive) or after (reactive, interactive mode only) the blueprints clone fails with an SSH auth error. Reactive path retries the clone automatically after key setup. Clone errors are classified from git stderr (auth / network / not-found / unknown) and produce targeted messages.
- Blueprint source is cached at `~/.local/share/machinekit/blueprints/` (machinekit-owned, treated as an ephemeral cache — wiped and re-fetched on every real-run apply).
- Cross-platform posture documented; macOS primary, Linux CI/e2e in place.

**Stock install** (what bootstrap puts on the machine with no extra config):

- Homebrew
- jq (powers `context::` store via JSON), toml2json, gomplate (renders dotfile templates), git (via brew, as prerequisites)
- mise (via brew, as part of the mise module)
- age (via the age module, when declared — manages the user's age private key)
- The dotfile templates above (blueprint-shipped) and the module-shipped defaults (gitconfig, mise config)

**Explicitly NOT in stock** (kept out by design):

- ripgrep / fd / bat / eza (opinion territory; users can add via their own blueprints)
- 1Password / `op` CLI
- oh-my-zsh, starship, or any other prompt theme
- Editor configs (`.editorconfig`, IDE settings) — repo-level concerns, not machine-level

**Deferred** (will be addressed in iteration 1.x or later):

- Curl-pipe-bash invocation. `machinekit apply` sources `lib/machinekit.sh` and `lib/modules.sh` from disk, so the one-liner needs a thin shim that clones machinekit first.

---

## Iteration 2 — Machine type branching

**Status: implemented.**

**Value**: blueprints can differentiate behavior per machine. A `personal` machine and a `server` machine running the same blueprints get appropriately different package sets and dotfile contents from the same source.

The directory structure (`machine_types/<type>/`) ships in iteration 1; this iteration wires up the *application* of those overrides.

**Deliverables:**

- Layered apply across the four moving pieces:
  - `home/` — apply `common/home/` then `machine_types/<type>/home/` on top. **Implemented.**
  - `Brewfile` — run `common/Brewfile`, then `machine_types/<type>/Brewfile` (additive). **Implemented.**
  - `hooks/post-apply/` — run common hooks, then type-specific hooks. **Implemented.**
  - `machinekit.toml` — load `common/machinekit.toml`, merge `machine_types/<type>/machinekit.toml` on top. **Implemented** (`config.sh` via `toml2json`).
- `machinekit.toml` reader — `config::load` parses both layers via `toml2json`, merges with `jq`, and stores the result in context. The `modules` key drives `preflight::resolve_active_modules` with topological dependency resolution. **Implemented.**
- Validation by provisioning at least one non-default machine type end-to-end. **Done.**

**Why a separate iteration**: machine-type layering is mechanically simple, but the structural decisions (directory shape, override semantics, TOML schema) are load-bearing for everything above. Getting them right before adding the module system avoids lock-in.

---

## Iteration 3 — Module system

**Status: implemented.**

**Value**: optional tools become declarative. You opt in via `machinekit.toml` and dependencies resolve automatically. This is the architectural mechanism behind [Tier 2 customization](./architecture.md#three-tier-customization).

**Deliverables:**

- `lib/modules/<name>.sh` convention with `::preflight`, `::install`, `::requires`, and `::provides` declarations. **Implemented.**
- TOML config reader for `machinekit.toml`: `config::load` merges common and machine-type layers; `config::get "module.<name>.<key>"` gives modules access to their config. **Implemented.**
- Dependency closure resolver: `resolver::resolve` does a DFS topological sort over `::requires` declarations so opting into one module pulls in its deps automatically. **Implemented.**
- Capability modules (`lib/modules/capabilities/`): `tool_version_manager` (default: `mise`) and `container_manager` (default: `orbstack` on macOS, `docker_ce` on Linux). Resolver substitutes the default satisfier, detects multi-satisfier conflicts. **Implemented.**
- Validation: concrete modules (`age`, `brewfile`, `git`, `mise`, `zsh`) and capability/satisfier resolution exercised end-to-end. **Done.**

**Why a separate iteration**: the module system is the highest-leverage architectural change in the project. Shipping it with one real module (mise) first means the abstractions are exercised against something non-trivial before more modules build on it.

---

## Iteration 4 — Bash 5.3+ bootstrap and modernization

**Status: planned (after the module system).**

**Value**: eliminates the bash 3.2 compatibility constraint from all lib files, unlocking modern bash features (`${ cmd; }` current-shell command substitution, `local -n` namerefs, associative arrays, etc.) and simplifying several internal patterns that currently work around 3.2 limitations.

**Deliverables:**

- `lib/machinekit/brew_core.sh` — pure, bash 3.2-compat brew primitives (`brew::_setup_path`, `brew::_run_installer`) with no lib dependencies. Sourced by both `brew.sh` and the bootstrap script.
- `lib/machinekit/bootstrap_bash.sh` — bash 3.2-compat entry script sourced at the top of bin files before any other lib. Checks bash version; if < 5.3, installs brew (if needed) and `brew install bash`, then re-execs the current script under the new shell. Uses `brew_core.sh` for shared logic.
- Refactor `context.sh` to use `${ cmd; }` current-shell command substitution, replacing the `_init_storage` two-call pattern and subshell guard.
- Remove the `MACHINEKIT_SUBSHELL_DEPTH` testability seam (no longer needed).
- Any other lib code that worked around bash 3.2 can be simplified.

**Why later**: the bash 3.2 constraint is a friction tax, not a blocker. All functionality can be built under 3.2; modernizing the shell is a quality-of-life pass best done once the feature surface is stable.

---

## Iteration 5+ — Onward

After the module system and bash modernization land, the framework's machinery is complete, and further work is driven by need rather than a planned phase list. Likely areas:

- Additional modules as needs arise (prompt themes, password-manager CLIs as a secrets-fetch layer, and so on).
- Linux support: add a Linux test target, gate macOS-specific lines behind `os.family` checks, validate the Homebrew-on-Linux path.
- A curl-pipe-bash installer shim (`install.sh`) for fresh-machine one-liner setup.

The roadmap stops being prescriptive here. The architecture supports incremental addition; what gets added is a function of what the framework actually needs in use.

---

## Deferred / explicitly-not-doing

Things considered and deliberately set aside:

| Item | Why deferred / declined |
|---|---|
| `brew bundle dump` for Brewfile generation | Captures transitive deps and makes Brewfiles unmaintainable. Brewfiles are crafted by hand. |
| Three-repo split (framework + public template + private user repo) | Two-repo split with internal template is cleaner: template stays in lockstep with the framework, and the init script does more than a "Use this template" button would. |
| HTTPS credential management for the blueprints clone | HTTPS tokens, `.netrc`, and credential helpers are git's job, not machinekit's. SSH key setup IS handled by the SSH module (see iteration 1). Keeping HTTPS out of scope preserves host-agnostic posture and avoids reimplementing what git already does well. |
| Silent age key generation when none found | A new key cannot decrypt files encrypted by a previous one; silent generation would lock users out of their own blueprints. Generation requires explicit consent. |
| Editor configs as a stock concern | `.editorconfig` and IDE settings are repo-level, not machine-level. Out of scope. |
| Prescriptive machine taxonomy | `machine_type` is an arbitrary string the user defines. The starter ships with `dev` and `server`; extend as needed. |
