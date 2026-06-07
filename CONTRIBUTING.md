# Contributing

## Running the test suite

Install [bats-core](https://bats-core.readthedocs.io/), then:

```bash
scripts/test
```

## Watching tests during development

Install [watchexec](https://github.com/watchexec/watchexec) (`brew install watchexec`), then:

```bash
scripts/watch-tests
```

Whenever you save a file in `lib/`, `tests/`, or `bin/`, the corresponding test file runs automatically. Saving `lib/modules/age.sh` runs `tests/lib/modules/age.bats`; saving a `.bats` file runs it directly. If a source file has no matching test file, the script says so rather than silently running nothing. Saving again while a run is in progress interrupts it and starts fresh.

## Running the linter

Install [shellcheck](https://www.shellcheck.net/), then:

```bash
scripts/lint
```

Both run automatically on push/PR via GitHub Actions.

## Adding a module

Each module lives in `lib/modules/<name>.sh`. The module must define:

- `<name>::preflight` — resolve inputs, publish values to context via `context::set`, no side effects.
- `<name>::install` — execute the plan; check `input::is_dry_run` before any mutation.

Default dotfile templates go in `lib/modules/<name>/templates/` and are layered into the staging dir before the blueprint's `common/home/`. See `lib/modules/git.sh` for the simplest example.

Read `docs/architecture.md` before making structural changes. Code conventions are in `CLAUDE.md`.

## Submitting changes

Open a pull request. Keep commits focused — one logical change per commit. For anything structural, open an issue first to discuss the approach.
