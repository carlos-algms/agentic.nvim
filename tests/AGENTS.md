# Testing Guide for agentic.nvim

Load the `agentic-testing` skill before creating, editing, or reviewing tests.
It owns the mini.test workflow, TDD red/green rules, helper APIs, child Neovim
patterns, async traps, and mark-count checks.

## Non-negotiables

- Bug fixes and behavioral changes need a failing test before the fix.
- The red failure must be behavioral, not missing setup, missing symbols, import
  errors, syntax errors, or nil method calls.
- After adding or modifying tests, verify the reported marks match the number of
  `it()` blocks in the changed file.
- Tests use project helpers, not luassert:
  - `tests.helpers.assert`
  - `tests.helpers.spy`
  - `tests.helpers.child`
- Read helper source before using helper APIs:
  - `tests/helpers/assert.lua`
  - `tests/helpers/spy.lua`
  - `tests/helpers/child.lua`

## Commands

```bash
make test
```

```bash
make test-file FILE=lua/agentic/acp/agent_modes.test.lua
```

For Lua or test code changes, run `make validate` after focused checks.
