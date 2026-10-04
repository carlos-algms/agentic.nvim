# Tests

Read this before you write or change any test, in any folder. Most tests live
next to their module as `lua/**/<module>.test.lua`; integration tests live in
`tests/integration/`.

The procedure (red/green steps, case-count check, child Neovim, async
references) is in skill `agentic-testing`. This file holds the rules. Each rule
exists because a test in this repo passed while the code was wrong.

## Framework

Tests run on mini.test with Busted emulation (`describe`, `it`, `before_each`,
`after_each`). Do not use luassert or Busted APIs from memory. Use the project
helpers and read their source before you call them:

- `tests/helpers/assert.lua`: `assert.equal(actual, expected)` takes the actual
  value FIRST, the reverse of Busted. mini.test then prints `Left: <actual>` /
  `Right: <expected>`
- `tests/helpers/spy.lua`: `spy.new`, `spy.on`, `spy.stub`. Spies have no
  `:call(n)`
- `tests/helpers/child.lua`: a child Neovim for async and editor-state tests

## TDD is mandatory

Every bug fix and behavior change starts with a failing test. Pure refactors,
formatting, and docs are exempt; say so in the PR.

The red failure must come from behavior: a wrong value, state, or output. A
missing module, nil method, syntax error, or import error is setup, not red.
Fix the setup and run again.

## A test must be able to fail

A test that passes for both the fixed and the broken code proves nothing. More
than half of all CodeRabbit findings in this repo were tests of this kind.

For each new or changed assertion, name the value that would make it fail. If
no reachable value fails it, the assertion is decoration.

Green is not done. After the test passes, revert the fix, run the test, and see
it fail. Then restore the fix. A test that stays green with the fix reverted
must be rewritten.

Assert the observable effect, not the deepest internal you can reach. If both
the correct branch and the broken branch write the same private field, an
assertion on that field passes for both, and the revert check above cannot
catch it. Assert what differs: the rendered buffer, the called callback, the
window that opened.

A test that checks a guard must also show WHICH guard fired. Assert the
precondition, not only the outcome. Example: `-1` can mean "hidden" or
"destroyed"; a test that only checks `-1` passes when the wrong guard fires.

## Never assert inside a deferred callback

mini.test runs each `it()` body inside `pcall`. A callback passed to
`vim.schedule`, `vim.defer_fn`, a `vim.uv` timer, or a coroutine runs AFTER that
`pcall` has returned. An assertion that fails there is not reported. The test
shows green, and the runner may drop the case from its count.

Store the value in the callback. Assert after the callback has run, in the
`it()` body. Prefer a child Neovim for code that schedules.

Two checks enforce this. At runtime, every `tests.helpers.assert` call inside a
callback queued by `vim.schedule` or `vim.defer_fn` during a test fails the run
(`tests/helpers/deferred_guard.lua`). Regression:
`tests/unit/test_deferred_guard.lua::"fails the run when an assertion runs in a deferred callback"`.
Statically, `make rules` flags `assert.` inside a `vim.schedule(function` or
`vim.defer_fn(function` block. Neither sees a `vim.uv` timer callback; that
case is still on you.

```lua
-- Bad: the failure is silently lost
it("updates the title", function()
    vim.schedule(function()
        assert.equal(widget.title, "new")
    end)
end)

-- Good: run in a child Neovim, flush, then assert in the it() body
it("updates the title", function()
    child.lua([[ require("x").update_title_async("new") ]])
    child.flush()
    assert.equal(child.lua_get([[ require("x").title ]]), "new")
end)
```

Same-process traps:

- `vim.uv.sleep()` does not run scheduled callbacks
- `vim.wait()` runs them, but can hide the case from mini.test's case count
- `assert.has_no_errors` cannot see an error raised later, in a deferred
  callback or across child RPC

More patterns: `references/async-tests.md` and `references/child-nvim.md` in
skill `agentic-testing`.

## Stubs and cleanup

Revert every stub and spy before the test's assertions, or in `after_each`. A
revert placed after an assertion never runs when that assertion fails, and the
stub leaks into every later test in the same process. Prefer `after_each`.

Never discard a `pcall` result in a test. `pcall(fn)` with the result ignored
swallows the exact failure the test exists to catch. Bind it and assert on it.

Teardown compares handle sets, never counts. Capture the baseline handles
(tabpages, windows, buffers) in `before_each`. In `after_each`, close only the
handles that are not in the baseline. A count-based loop that closes the
current tabpage can close a baseline tabpage and leave the test's own tabpage
open.

When you fix a leak in one test case, grep the whole file for the same
acquisition pattern first. If several cases share it, move the cleanup into a
shared `before_each` / `after_each` instead of fixing one case.

Clean up everything a test creates: buffers, windows, tabpages, autocommands,
globals, stubs, and spies.

## Isolation

- ACP and transport tests must stub `agentic.acp.acp_transport`, or anything
  else that opens a subprocess or a network call. Use
  `tests/mocks/acp_transport_mock.lua`. It delivers messages by direct call, so
  it cannot produce a fast event context; use a child Neovim and a `vim.uv`
  timer for that
- All tests run in one Neovim process, in sequence, unless you use
  `tests.helpers.child`. State left by one test is seen by the next
- CI is Linux-only. Do not add Windows guards. `/bin/sh`, `kill -0`, and POSIX
  process-group behavior are intentional

## Commands

```bash
make test-file FILE=lua/agentic/acp/agent_modes.test.lua
```

Use `make test-file` for the red/green loop. It runs one file in seconds.
