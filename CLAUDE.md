# CLAUDE.md

Instructions for Claude Code (or similar LLM coding agents) working in this repo.

## Where to read first

- [README.md](./README.md) — what machinekit is and how to use it.
- [docs/architecture.md](./docs/architecture.md) — why machinekit works the way it does. Read this before making structural changes.
- [docs/roadmap.md](./docs/roadmap.md) — what's built, what's planned, what's deferred and why.

If a per-user plan doc exists at `~/.claude/plans/machinekit.md`, it contains the maintainer's situational context (current machine state, personal config, in-progress decisions) that doesn't belong in the public repo. Read it when working on this project locally.

## Working norms for this repo

These are non-obvious from reading the code alone:

1. **This is a public repo.** Never commit personal config, secrets, or identifying details. Personal context belongs in the maintainer's blueprints repo (private) or in the per-user plan doc above. Keep specific product direction — particular tools or services the maintainer plans to build modules for, machine-type taxonomies, identity-laden examples — out of the public docs and templates; examples here stay deliberately generic.

2. **Explicit consent for irreversible actions.** This is a core design rule (see [architecture.md § The explicit-consent rule](./docs/architecture.md#the-explicit-consent-rule)). Any code path that generates keys, opens browsers, mutates remote state, or otherwise touches the outside world must require a flag, env var, or interactive confirmation. Local idempotent installs do not.

3. **OS-agnostic posture.** macOS and Linux are both supported; the framework is designed to stay portable. When adding code: don't hardcode brew prefix paths, gate macOS-only template content behind `{{ if eq .os.family "darwin" }}`, frame module dependencies as capabilities (e.g. "container runtime") rather than specific tools.

4. **Iterations are scope-boxed, not time-boxed.** Don't tackle iteration N+1 work as part of iteration N "while you're in there." See `docs/roadmap.md` for what each iteration is delivering.

5. **No `brew bundle dump`.** Brewfiles are crafted by hand; each entry is intentional. See architecture for rationale.

6. **Bash scripts target macOS-shipped bash (3.2-compatible) on first run.** Until Homebrew installs newer bash, the entry script runs under `/bin/bash`. Avoid bash 4+ features (`mapfile`, `declare -A`, `${var,,}`) in `bin/machinekit-apply` and anything sourced before brew is on PATH.

## Code style for this repo

- Shell scripts use `set -euo pipefail`. `bin/` files source `lib/machinekit.sh`, which aggregates all of `lib/machinekit/*` eagerly. Modules in `lib/modules/` are lazy-sourced via `modules::source_all` when the resolver or install pipeline needs them. Every file uses a namespace matching its filename — `logging::*` in `logging.sh`, `lifecycle::*` in `lifecycle.sh`, `context::*` in `context.sh`, `brew::*` in `brew.sh`, `age::*` in `age.sh`, etc.
- **snake_case for all identifiers** — variables, context keys, JSON paths, template fields. No camelCase, even when the destination format (TOML) commonly uses it.
- **`context::` is the jq-backed runtime data store.** Use `context::set` / `context::get` with snake_case dotted keys (`git.user_name`, `age.key_path`, `modules.active`) for scalars; `context::set_array` / `context::get_array` for arrays. `jq` and `toml2json` are installed by `prerequisites::install` before preflight runs (`jq` powers the context store; `toml2json` parses `machinekit.toml`), so context functions are available everywhere downstream — just not during prerequisite installation itself. (gomplate, the `.tmpl` renderer, is a base module installed in the module stage — not a prerequisite. See below.)
- Modules can ship default dotfile templates in `lib/modules/<name>/templates/`. The staging-dir builder layers these first, then the blueprint's `common/home/` on top, then `machine_types/<type>/home/` on top of that (when a machine type is set).
- **Home content transforms** live in `lib/machinekit/home/transforms.sh` (`home::transforms::*`). A module that transforms file content by extension declares one hook, `<name>::file_transforms`, emitting `ext tier handler` lines (`tier` ∈ {`decode` for decrypt/decompress, `content` for templating}); the handler is `fn IN_PATH → stdout`. Markers register in preflight, scoped to active modules; decode-tier markers must be outermost (rightmost) on the filename. **Base modules** (`MK_BASE_MODULES` in `modules.sh`) are framework-owned and always active — gomplate is one (it owns the `.tmpl` handler and its context plumbing).
- Logging goes to stderr; only intentional script output goes to stdout.
- Comments explain *why*, not *what*. No multi-paragraph docstrings.

## Testing

Tests live in `tests/lib/`, mirroring the `lib/` directory structure (e.g. `tests/lib/machinekit/brew.bats` covers `lib/machinekit/brew.sh`). Run with `bats tests/`.

Stub infrastructure lives in `tests/helpers/stubbing.sh`. Read it before writing stubs — it defines `mktest::stub_function` (allow-style: sets up the fake), `mktest::assert_stub_called` / `mktest::assert_stub_not_called` (expect-style: asserts invocation). STUB_OUTPUT, STUB_RETURN, and positional-arg matching are covered there.

**Before writing or reviewing any test, load `~/.claude/memory/feedback_testing_principles.md`** (global memory). It covers behavior vs mechanism, the AND pattern, the integrated anti-pattern, stubs-as-wiring, parameterized-output stubs as self-asserting, logging-as-mechanism, guard-code coverage, setup source discipline, exit-function limitations, source-time extraction, and testability seams. The project auto-memory index (loaded by the harness) also has a machinekit-specific companion file with bats/stub implementation details — read both.

## When making documentation changes

The four-document split is intentional:

- **README.md** — current capabilities, quick start. No "iteration" language, no aspirational features.
- **docs/architecture.md** — how the framework works and the reasoning behind its structure, with "Status: not yet implemented" flags on parts that aren't done. When a feature lands, flip the flag rather than rewriting. Keep it about the framework itself; personal/product direction (e.g. specific tools the maintainer plans to build modules for) lives in the per-user plan doc, not here.
- **docs/roadmap.md** — what's done, what's next, why each step.
- **CLAUDE.md** — this file. Stays thin. Defers content to the three docs above unless there's a reason an LLM specifically needs it inline (token-efficiency, agent-behavior guidance).

Don't let CLAUDE.md re-accumulate content that belongs in the other three.
