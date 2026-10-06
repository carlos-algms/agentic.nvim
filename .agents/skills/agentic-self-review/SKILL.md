---
name: agentic-self-review
description: >
  Use in agentic.nvim when reviewing a diff before a commit: your own work, a
  sub-agent's, or as the reviewer in a plan review loop. Checks that tests can
  fail, that every routed rule holds for the changed files, and that unchanged
  sibling code still holds. Runs no full gate.
---

# Self-review

One review per diff. If this diff already passed a review and no file changed
since, do not review it again.

Run read-only commands only, plus `make test-file FILE=<path>` for the revert
check in step 1. This review trusts the gates that already passed: never run
`make validate`, `make test`, lint, or types.

## Checklist

Create a task list with these items. Mark each `completed` only when it is done
for every changed file.

1. **Tests can fail.** For each new or changed assertion, name the value that
   would make it fail. None reachable -> the assertion is decoration. For a
   bug-fix test, undo the fix, run `make test-file FILE=<path>`, confirm red,
   restore the fix
2. **Observable effect.** Does an assertion read a private field that both the
   correct and the broken branch write? Then it cannot fail. Assert the public
   effect instead
3. **Async.** No assertion inside a `vim.schedule`, `vim.defer_fn`, timer, or
   coroutine callback. Store the value, assert in the `it()` body
4. **Cleanup.** Stubs reverted before assertions or in `after_each`; no
   discarded `pcall` result; teardown compares handle sets, not counts
5. **Rule sweep.** For each changed file, open every doc its router row names.
   Check every rule in those docs against the diff, not only the rules you
   remember. Include test mocks: they follow the same rules as production code
6. **New rules.** If the diff adds or edits a rule in any `AGENTS.md` or skill,
   check that rule against every function in the same diff. A new runtime rule
   must cite a test
7. **Siblings.** For each fixed or guarded path, read the unchanged sibling
   paths in the same function and its callers (`rg` the symbol). Does the
   change's premise make any unchanged line wrong?
8. **Transitive context.** For code that runs in a libuv callback, follow every
   call it makes. The fast-event ban applies to the whole call chain
9. **Rule gaps.** Every gap found goes to skill `agentic-learn`

## Output

Report findings as `file:symbol - problem - fix`. Fix them, or hand them back
to the agent that owns the commit. Report "no findings" when there are none.
