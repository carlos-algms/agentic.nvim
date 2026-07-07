---
name: agentic-testing
description: >
  MANDATORY before creating, editing, or reviewing tests in agentic.nvim, and
  before behavior changes that require TDD. Covers mini.test workflow, red/green
  rules, commands, mark-count checks, and which test references to load.
---

# Agentic Testing

## Framework

- mini.test with Busted-style emulation.
- Test files live next to source files as `<module>.test.lua`.
- `tests/` holds the runner, helpers, functional tests, and integration tests.
- The previous Busted/lazy.nvim setup is gone.

## TDD

For every bug fix or behavioral change:

1. Bootstrap missing symbols first so the test loads.
2. Write the failing assertion.
3. Run the focused test with `make test-file FILE=<path>` and confirm it fails
   for behavior, not setup:
   1. wrong: missing module, nil method, syntax error, unresolved import
   2. right: value/state/output mismatch
4. Implement the minimum code to pass.
5. Re-run `make test-file FILE=<path>`.
6. Run the relevant full check.
7. After adding or changing tests, reconcile the case count. This guards against
   silently dropped OR unexpectedly generated tests. Both are failures.
   1. Compute EXPECTED cases by reading the file, not grepping:
      - each static `it()` = 1 case
      - each `it()` inside a `for`/`each`/table-driven loop = the loop's
        iteration count (a single `it(` line can emit many cases, or zero)
      - a grep of `it(` is a lower bound, never the answer
   2. Read ACTUAL from `Total number of cases: N` in the
      `make test-file FILE=<path>` output.
   3. EXPECTED MUST equal ACTUAL. Mismatch = a test was dropped, a loop is empty,
      or a generator misfired; stop and reconcile before claiming green.
      Eyeballing ACTUAL alone is NOT the check - you must derive EXPECTED first.

Pure refactors, formatting, and docs can skip red/green, but say that in the PR.

## Commands

```bash
make test
```

```bash
make test-file FILE=lua/agentic/acp/agent_modes.test.lua
```

Use `make test-file FILE=<path>` for the red/green inner loop; it runs one file
in seconds. Never run `make validate` between iterations. After all `.lua`
edits, run `make validate` and fix until it passes - the task is not done until
it does. Pre-commit gate, not a per-test step.

For Lua or test changes, root `AGENTS.md` requires `make validate` after the
focused checks.

## Before writing assertions

Read the exact helper APIs before using them:

- `tests/helpers/assert.lua`
- `tests/helpers/spy.lua`
- `tests/helpers/child.lua` when using child Neovim tests

Load references only when needed:

- `references/assert-spy.md`: custom assert, spy, and stub API details.
- `references/child-nvim.md`: child process tests and RPC helpers.
- `references/async-tests.md`: scheduled/deferred code and mark-count traps.

## Defaults

- Unit tests: co-located `<module>.test.lua`.
- Integration or functional tests: `tests/integration/` or `tests/functional/`
  when behavior spans modules or needs real editor state.
- ACP or transport-touching tests must stub `agentic.acp.acp_transport` or any
  dependency that opens subprocesses or network calls.
- Tests run sequentially in one Neovim process unless you explicitly use
  `tests.helpers.child`.
- Clean up buffers, windows, autocommands, globals, stubs, and spies.
