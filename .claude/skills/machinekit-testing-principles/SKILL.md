---
name: machinekit-testing-principles
user-invocable: false
description: "Testing guide for this repo — unit-testing principles (behavior vs mechanism, the AND pattern, golden path, guard coverage) plus machinekit's bats/stub mechanics: test layout, the mktest stub API, jq/dasel don't-stub, and the watcher. Apply before writing or reviewing any test."
---

How tests work in machinekit, and the principles they follow. Tests are bats unit tests under `tests/lib/`; the stub framework is `tests/helpers/stubbing.sh`.

## Principles

The unit under test is a **single function**, not a file or module. Classify it first, then assert accordingly:
- **Orchestrator** (coordinates collaborators): its contract *is* the coordination — which collaborators it calls, with what arguments, in what order where order is load-bearing, and the data threaded between them. Assert the whole cascade, not a sample.
- **Computation** (returns a value or changes state): assert the return value or state change, not the internal steps.

- **Stub every collaborator** — even one in the same file (it has its own tests; its behavior is its own responsibility). A real collaborator running in place of a stub is the *integrated anti-pattern*: it couples the test to another unit's internals. You don't need to source a collaborator's file to stub it.
- **Stub vs. let-it-run:** stub when the collaborator owns the outcome or has external/expensive side effects (network, real git, another module). Let it run when *you* specified the outcome — e.g. a `mkdir`/`cp` to a path the test controls — and assert the result directly.
- **AND pattern:** related outcomes of one case belong in one test ("dest prepared AND fetcher called with the source"), not split into separate tests.
- **Golden path first and mandatory:** every unit gets a test for its primary success behavior, written before any edge/guard test. If every test name is "when X is missing/invalid/fails," the actual contract is untested.
- **Guard coverage:** every conditional (early return, skip-on-condition, boundary check) needs a test that *fires* it — an untested guard is an unverified claim.
- **Assertions are contract; stubs are wiring.** Assert a collaborator call only when the call itself is the outcome under test. Output/logging stubs are allow-only — assert a message only when it is the user-facing contract (an error explaining a failure, a summary of what would happen), not internal progress.
- **Assert the identifying token, not the full message** — match the token that distinguishes this case from others in the same function; leave wording free unless the exact string is a public contract (a parseable CLI string, a documented schema).
- **TDD:** write the test before the code; red → green → refactor; at each layer (function, option, branch).
- **Verify regression probes:** strip the fix, confirm the test goes red, restore. A test that passes with or without the fix proves nothing.

## Layout & running
- Tests live in `tests/lib/`, mirroring `lib/` (e.g. `tests/lib/machinekit/brew.bats` covers `lib/machinekit/brew.sh`).
- Run a targeted file: `bats tests/lib/modules/age.bats` (optionally `-f <pattern>` to scope further). Run the affected file rather than the whole suite on every change.
- This repo ships `scripts/watch-tests`, which reruns affected tests on save. While iterating with it running, don't re-run bats yourself — it's redundant.

## Stub infrastructure (`tests/helpers/stubbing.sh`)
- `mktest::stub_function FUNC [ARGS]` = **allow** (set up the fake). `mktest::assert_stub_called` / `assert_stub_not_called` / `assert_stub_called_in_order` = **expect** (assert invocation). `STUB_OUTPUT` / `STUB_RETURN` / `STUB_ERROR` / `STUB_EXIT` configure a stub; `MATCH=regex` / `TIMES=N` modify an assertion.
- **Never-called corollary:** `assert_stub_not_called` errors if the function was never stubbed at all — "never stubbed" ≠ "never called", so stub it before asserting it wasn't called.
- **Test isolation:** each `@test` runs in its own subshell; stub definitions and `$BATS_TEST_TMPDIR` files are test-scoped. `setup()` resets module-level vars (e.g. `_MK_BREW_FORMULAE_CACHED=0`), not stubs.
- **Exit-collaborators:** functions that `exit` instead of returning (e.g. `lifecycle::fail`) need a stub that both exits and records the call: `STUB_EXIT=1 mktest::stub_function lifecycle::fail`. Never an inline `lifecycle::fail() { exit 1; }` — it can't be asserted on.
- **Resource seam:** `${MACHINEKIT_TTY:-/dev/tty}` for testable tty reads; tests write to `$BATS_TEST_TMPDIR/tty` and export `MACHINEKIT_TTY`.
- **Exact-arg stubs over trailing wildcards:** a no-args `mktest::stub_function FUNC` matches any call (first-matching-rule-wins), a fragile fallthrough that can silently absorb the wrong call. Prefer exact args. When production bakes a runtime value into an arg (e.g. a `--prompt` string with a path), extract it to a module constant (see `_AGE_GENERATE_PROMPT` / `_AGE_OVERWRITE_PROMPT` in `age.sh`, built via `printf -v`) so test and production share one source and the stub matches exactly.
- **Piped stdin:** mktest records args only — for a collaborator fed via stdin, hand-roll a capture stub (`mgr() { printf '%s\n' "$@" >args; cat >stdin; }`) and assert the captured stdin.

## Don't stub jq or dasel
`tests/helpers/stubbing.sh` uses `jq` internally — stubbing it causes infinite recursion and hangs. `dasel` is a prerequisite present in any test environment; stubbing it causes SIGPIPE under `pipefail` (the stub exits without reading stdin). Let both run for real and assert against their actual output (e.g. parse TOML output with `dasel`).
