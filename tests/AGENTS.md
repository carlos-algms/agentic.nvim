# Testing Guide for agentic.nvim

**Framework:** mini.test with Busted-style emulation

**Why:**

- No external dependencies (pure Lua, no hererocks/nlua needed)
- Built-in child Neovim process support for isolated testing
- Busted-style syntax via `emulate_busted = true`
- Automatic bootstrap (clones mini.nvim on first run)
- Single Neovim process execution model with child processes for isolation

**Previous framework:** Busted with lazy.nvim's (completely removed)

## Test File Organization

**Location:** Co-located with source files in `lua/` directory

**Pattern:** `<module>.test.lua` next to `<module>.lua`

**Example structure:**

```
lua/agentic/
  ├── init.lua
  ├── init.test.lua
  ├── session_manager.lua
  ├── session_manager.test.lua
  └── utils/
      ├── logger.lua
      └── logger.test.lua
```

**Why co-located:**

- Easy to find related test
- Clear coupling between code and tests
- Better developer experience for navigation

**Note:** `tests/` directory contains:

- `tests/init.lua` - Test runner
- `tests/helpers/spy.lua` - Spy/stub utilities
- `tests/unit/` - Legacy/shared test files (if needed)
- `tests/functional/` - Functional tests
- `tests/integration/` - Integration tests that requires multiple components

## Running Tests

### Basic Usage

```bash
# Run all tests
make test

# Run with verbose output
make test-verbose

# Run specific test file
make test-file FILE=lua/agentic/acp/agent_modes.test.lua
```

### First Run

First run will be slower as it clones mini.nvim to `deps/` directory
(gitignored). Subsequent runs are fast.

## Test Structure

### Busted-Style Syntax (describe/it)

mini.test with `emulate_busted = true` provides familiar Busted syntax:

```lua
local assert = require('tests.helpers.assert')

describe('MyModule', function()
  --- @type agentic.mymodule add actual existing module type to avoid `any` or `unknown`
  local MyModule

  before_each(function()
    MyModule = require('agentic.mymodule')
  end)

  after_each(function()
    -- Cleanup
  end)

  it('does something', function()
    local result = MyModule.function_name()
    assert.equal('expected', result)
  end)
end)
```

### Available Busted-Style Functions

| Function             | Description                        |
| -------------------- | ---------------------------------- |
| `describe(name, fn)` | Group tests (alias: `context`)     |
| `it(name, fn)`       | Define test case (alias: `test`)   |
| `pending(name)`      | Skip test                          |
| `before_each(fn)`    | Run before each test in block      |
| `after_each(fn)`     | Run after each test in block       |
| `setup(fn)`          | Run once before all tests in block |
| `teardown(fn)`       | Run once after all tests in block  |

### Assertions (Custom Assert Module)

**IMPORTANT:** Use the custom `tests.helpers.assert` module which provides a
familiar Busted/luassert-style API while wrapping mini.test's expect functions:

```lua
local assert = require('tests.helpers.assert')

-- Equality assertions
assert.equal(expected, actual)          -- Basic equality
assert.same(expected, actual)           -- Deep equality (same as equal)
assert.are.equal(expected, actual)      -- Busted-style variant
assert.are.same(expected, actual)       -- Busted-style variant

-- Negated equality
assert.are_not.equal(expected, actual)  -- Not equal
assert.is_not.equal(expected, actual)   -- Not equal (alternate)

-- Type checks
assert.is_nil(value)                    -- Value is nil
assert.is_not_nil(value)                -- Value is not nil
assert.is_true(value)                   -- Value is true
assert.is_false(value)                  -- Value is false
assert.is_table(value)                  -- Value is a table

-- Truthy/falsy checks
assert.truthy(value)                    -- Value is truthy
assert.is_falsy(value)                  -- Value is falsy

-- Error handling
assert.has_no_errors(function() ... end)  -- Function does not throw

-- Spy/stub assertions
local spy = require('tests.helpers.spy')
local my_spy = spy.new(function() end)
my_spy()
assert.spy(my_spy).was.called(1)        -- Called once
assert.spy(my_spy).was.called_with(...)  -- Called with specific args
```

### Direct MiniTest.expect Usage

For assertions not covered by the custom assert module, use MiniTest.expect:

```lua
local MiniTest = require('mini.test')
local expect = MiniTest.expect

-- Error testing with pattern matching
expect.error(function() ... end)        -- Function throws error
expect.error(function() ... end, 'msg') -- Error matches pattern
```

## Spy/Stub Utilities

mini.test doesn't include luassert's spy/stub functionality. Use the provided
helper module:

```lua
local spy = require('tests.helpers.spy')
```

### Creating Spies

```lua
local assert = require('tests.helpers.assert')
local spy = require('tests.helpers.spy')

-- Create a standalone spy
local callback_spy = spy.new(function() end)

-- Pass spy as callback (type cast for luals)
some_function(callback_spy --[[@as function]])

-- Check call count using custom assert
assert.equal(1, callback_spy.call_count)
assert.spy(callback_spy).was.called(1)  -- Called exactly once
assert.spy(callback_spy).was.called(0)  -- Not called (use 0)

-- Or using MiniTest.expect directly
local expect = require('mini.test').expect
expect.equality(callback_spy.call_count, 1)

-- Check if called with specific arguments
assert.is_true(callback_spy:called_with('arg1', 'arg2'))
assert.spy(callback_spy).was.called_with('arg1', 'arg2')

-- Get arguments from specific call
local args = callback_spy:call(1)  -- First call arguments
```

### Spying on Existing Methods

```lua
local assert = require('tests.helpers.assert')
local spy = require('tests.helpers.spy')

-- Create spy on existing method
local feedkeys_spy = spy.on(vim.api, 'nvim_feedkeys')

-- Method still works, but calls are tracked
vim.api.nvim_feedkeys('keys', 'n', false)

-- Check calls using custom assert
assert.equal(1, feedkeys_spy.call_count)
assert.is_true(feedkeys_spy:called_with('keys', 'n', false))

-- Or using MiniTest.expect directly
local expect = require('mini.test').expect
expect.equality(feedkeys_spy.call_count, 1)
expect.equality(feedkeys_spy:called_with('keys', 'n', false), true)

-- IMPORTANT: Always revert in after_each
feedkeys_spy:revert()
```

### Creating Stubs

```lua
local assert = require('tests.helpers.assert')
local spy = require('tests.helpers.spy')

-- Create stub that replaces a method
local fs_stat_stub = spy.stub(vim.uv, 'fs_stat')

-- Set return value
fs_stat_stub:returns({ type = 'file' })

-- Or set a function to invoke
fs_stat_stub:invokes(function(path)
  if path == '/exists' then
    return { type = 'file' }
  end
  return nil
end)

-- Check calls using custom assert
assert.equal(1, fs_stat_stub.call_count)

-- Or using MiniTest.expect directly
local expect = require('mini.test').expect
expect.equality(fs_stat_stub.call_count, 1)

-- IMPORTANT: Always revert in after_each
fs_stat_stub:revert()
```

### Spy/Stub Best Practices

```lua
local assert = require('tests.helpers.assert')
local spy = require('tests.helpers.spy')

describe('MyModule', function()
  local my_stub

  before_each(function()
    my_stub = spy.stub(vim.api, 'some_function')
    my_stub:returns('mocked')
  end)

  after_each(function()
    my_stub:revert()  -- CRITICAL: Always revert!
  end)

  it('uses stubbed function', function()
    -- Test code here
    assert.equal(1, my_stub.call_count)
    -- Or: require('mini.test').expect.equality(my_stub.call_count, 1)
  end)
end)
```

## Test Types

### Unit Tests

- Test individual functions/modules in isolation
- Heavy use of spies/stubs
- Fast execution
- Located next to source: `<module>.test.lua`

### Functional Tests

- Test plugin behavior in real Neovim environment
- Minimal mocking
- Tests actual Neovim integration
- Can be in `tests/functional/` if complex

### Integration Tests

- Test multiple components working together
- Test external dependencies (ACP providers, etc.)
- Can be in `tests/integration/` if complex
- **IMPORTANT:** Mock `transport.lua` to avoid exposing API tokens in tests

## Mocking Transport Layer

When testing ACP providers or any code that makes external requests, always mock
the transport layer:

```lua
local assert = require('tests.helpers.assert')
local spy = require('tests.helpers.spy')

describe('ACP provider', function()
  local transport_stub

  before_each(function()
    local transport = require('agentic.acp.transport')
    transport_stub = spy.stub(transport, 'send')
    transport_stub:returns({
      type = 'message',
      content = 'mocked response',
    })
  end)

  after_each(function()
    transport_stub:revert()
  end)

  it('sends messages without real API calls', function()
    -- Test code
    assert.equal(1, transport_stub.call_count)
  end)
end)
```

## Important Notes

### Test Execution Model

**🚨 CRITICAL: Understanding mini.test's Execution Model**

**Tests run sequentially in a single Neovim process:**

- ✅ Tests execute **one after another** (not in parallel)
- ⚠️ All tests share the **same Neovim instance**
- ⚠️ Tests **CAN affect each other** through shared global state
- ⚠️ Module caching means `require()` returns the same module instance
- ⚠️ Neovim APIs operate on the same editor state

**Critical implications:**

1. **Always clean up resources** - Buffers, windows, autocommands left behind
   affect subsequent tests
2. **Module-level state persists** - Variables retain values between tests
3. **Global Neovim state persists** - Vim variables, options carry over
4. **Always revert stubs/spies** - Failure to revert breaks subsequent tests

### Multi-Tabpage Testing

Since agentic.nvim supports **one session instance per tabpage**, tests must
verify:

- Tabpage isolation (no cross-contamination)
- Independent state per tabpage
- Proper cleanup when tabpage closes

Example:

```lua
it('maintains separate state per tabpage', function()
  local tab1 = vim.api.nvim_get_current_tabpage()
  require('agentic').toggle()

  vim.cmd('tabnew')
  local tab2 = vim.api.nvim_get_current_tabpage()
  require('agentic').toggle()

  -- Verify both tabpages have independent sessions
end)
```

### Child Neovim Process Testing

For isolated integration tests, use mini.test's child process:

```lua
local assert = require('tests.helpers.assert')
local Child = require('tests.helpers.child')

describe('integration', function()
  local child = Child.new()

  before_each(function()
    child.setup()  -- Restarts child and loads plugin
  end)

  after_each(function()
    child.stop()
  end)

  it('loads plugin correctly', function()
    local loaded = child.lua_get([[package.loaded['agentic'] ~= nil]])
    assert.is_true(loaded)
    -- Or: require('mini.test').expect.equality(loaded, true)
  end)
end)
```

#### Child Instance Redirection Tables

The child Neovim instance provides "redirection tables" that wrap corresponding
`vim.*` tables, but gets executed in the child process:

**API Access:**

- `child.api` - Wraps `vim.api`
- `child.api.nvim_buf_line_count(0)` - Returns result from child process

**Variable and Option Access:**

- `child.o` - Global options (`vim.o`)
- `child.bo` - Buffer options (`vim.bo`)
- `child.wo` - Window options (`vim.wo`)
- `child.g`, `child.b`, `child.w`, `child.t`, `child.v` - Variables

**Function Execution:**

- `child.fn` - Wraps `vim.fn`
- `child.lua(code)` - Executes multi-line Lua code and returns result
- `child.lua_get(code)` - Executes single-line Lua expression and returns result
  (auto-prepends `return`)
- `child.lua_func(fn, ...)` - Executes a Lua function with parameters

**Common Patterns:**

```lua
-- Get window count
local win_count = #child.api.nvim_tabpage_list_wins(0)
assert.equal(3, win_count)

-- Check buffer line count
local lines = child.api.nvim_buf_line_count(0)

-- Get option value
local colorscheme = child.o.colorscheme

-- Count table entries - use vim.tbl_count
local count = child.lua_get([[vim.tbl_count(some_table)]])

-- Execute Lua and get single value result
local result = child.lua_get([[require('mymodule').get_state()]])

-- Execute multi-line Lua code and return result
local filetypes = child.lua([[
  local fts = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    table.insert(fts, vim.bo[vim.api.nvim_win_get_buf(winid)].filetype)
  end
  table.sort(fts)
  return fts
]])
```

**Critical Guidelines:**

- **Use `#` operator with child.api results** -
  `#child.api.nvim_tabpage_list_wins(0)` instead of wrapping in `lua_get`
- **Use `vim.tbl_count()`** for counting table entries - Never manually iterate
  with pairs()
- **`child.lua_get()` limitations:**
  - Auto-prepends `return` - ONLY for single-line expressions
  - CANNOT use multi-line code (will error with "unexpected symbol")
  - For multi-line code, use `child.lua()` instead
- **When to use `child.lua()` vs `child.lua_get()`:**
  - Single expression returning a value: `child.lua_get([[expression]])`
  - Multi-line code or complex logic: `child.lua([[code]])`

**Limitations:**

- Cannot use functions or userdata for child's inputs/outputs
- Move computations into child process rather than passing complex types

#### Waiting for Async Operations in Child Process

**🚨 CRITICAL: `vim.wait()` doesn't work with child processes**

- **Problem:** `vim.wait()` fails across RPC boundaries (E5560 error in Neovim
  0.10+)
- **Solution:** Use `vim.uv.sleep()` in parent test, not `vim.wait()` in child

```lua
-- ❌ WRONG: vim.wait() in child doesn't work
child.lua([[vim.wait(10)]])

-- ✅ CORRECT: vim.uv.sleep() in parent
child.lua([[-- async operation that sets vim.b.result]])
vim.uv.sleep(10)  -- Wait in parent for child to complete
local result = child.lua_get("vim.b.result")
```

**Why:** `vim.wait()` processes events and creates lua loop callback contexts
where it's prohibited. `vim.uv.sleep()` is a simple blocking sleep that lets the
child continue independently.

## Debugging Tests

### Verbose Output

```bash
make test-verbose
```

### Debug Specific Test

```bash
make test-file FILE=lua/agentic/init.test.lua
```

## Resources

- [mini.test Documentation](https://raw.githubusercontent.com/nvim-mini/mini.test/refs/heads/main/README.md)
- [mini.test Help](https://raw.githubusercontent.com/nvim-mini/mini.nvim/refs/heads/main/doc/mini-test.txt)
