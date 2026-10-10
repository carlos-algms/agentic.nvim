---
name: agentic-testing
description: >
  MANDATORY before creating, editing, or reviewing tests, and before TDD
  behavior changes. Covers mini.test red/green, revert check, which test
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
5. Fix and re-run `make test-file FILE=<path>` until green.
6. Revert check: undo the fix (keep the test), run
   `make test-file FILE=<path>`, and confirm red. Restore the fix. Still green
   with the fix undone = the test does not discriminate; rewrite it (see "A
   test must be able to fail" in `tests/AGENTS.md`). A test that exists only to
   force a type check goes red under `make luals`, not `make test-file`; run
   the revert check there.

Use `make test-file FILE=<path>` for the whole loop. It runs one file in
seconds.

## Load references only when needed

- `references/assert-spy.md`: custom assert, spy, and stub API details
- `references/child-nvim.md`: child process tests and RPC helpers
- `references/async-tests.md`: scheduled and deferred code
