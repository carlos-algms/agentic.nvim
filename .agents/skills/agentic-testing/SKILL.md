---
name: agentic-testing
description: >
  MANDATORY before creating, editing, or reviewing tests in agentic.nvim, and
  before behavior changes that require TDD. Covers the mini.test red/green
  procedure, the revert check, case-count reconciliation, and which test
  references to load.
---

# Agentic Testing

The rules are in `tests/AGENTS.md`. Read it first. This skill holds the
procedure.

## TDD procedure

For every bug fix or behavioral change:

1. Bootstrap missing symbols first so the test loads.
2. Write the failing assertion.
3. Run `make test-file FILE=<path>` and confirm it fails for behavior, not
   setup:
   1. wrong: missing module, nil method, syntax error, unresolved import
   2. right: value/state/output mismatch
4. Implement the minimum code to pass.
5. Re-run `make test-file FILE=<path>` until green.
6. Revert check: undo the fix (keep the test), run `make test-file`, and confirm
   red. Restore the fix. Still green with the fix undone = the test does not
   discriminate; rewrite it (see "A test must be able to fail" in
   `tests/AGENTS.md`).
7. Reconcile the case count. This guards against silently dropped OR
   unexpectedly generated tests. Both are failures.
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

Use `make test-file FILE=<path>` for the whole loop. It runs one file in
seconds.

## Load references only when needed

- `references/assert-spy.md`: custom assert, spy, and stub API details
- `references/child-nvim.md`: child process tests and RPC helpers
- `references/async-tests.md`: scheduled/deferred code and case-count traps
