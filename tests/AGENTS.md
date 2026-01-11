# Testing Guide for agentic.nvim

## Testing Framework Decision

**Framework:** mini.test with Busted-style emulation

**Why:**

- No external dependencies (pure Lua, no hererocks/nlua needed)
- Built-in child Neovim process support for isolated testing
- Busted-style syntax via `emulate_busted = true`
- Automatic bootstrap (clones mini.nvim on first run)
- Single Neovim process execution model

**Previous framework:** Busted with lazy.nvim's `minit.busted()`

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

### Manual Execution

```bash
# Run all tests
nvim --headless -u tests/init.lua -c "lua MiniTest.run()"

# Run specific file with verbose output
nvim --headless -u tests/init.lua -c "lua MiniTest.run_file('lua/agentic/acp/agent_modes.test.lua', {execute = {reporter = MiniTest.gen_reporter.stdout({})}})"
```

### First Run

First run will be slower as it clones mini.nvim to `deps/` directory (gitignored).
Subsequent runs are fast.

## Test Structure

### Busted-Style Syntax (describe/it)

mini.test with `emulate_busted = true` provides familiar Busted syntax:

```lua
local MiniTest = require('mini.test')
local expect = MiniTest.expect

describe('MyModule', function()
  local MyModule

  before_each(function()
    MyModule = require('agentic.mymodule')
  end)

  after_each(function()
    -- Cleanup
  end)

  it('does something', function()
    local result = MyModule.function_name()
    expect.equality(result, 'expected')
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

### Assertions (MiniTest.expect)

**IMPORTANT:** mini.test does NOT provide luassert's `assert.*` functions. Use
`MiniTest.expect.*` instead:

```lua
local MiniTest = require('mini.test')
local expect = MiniTest.expect

-- Equality
expect.equality(actual, expected)       -- Deep equality
expect.no_equality(actual, expected)    -- Not equal

-- Error testing
expect.error(function() ... end)        -- Function throws error
expect.error(function() ... end, 'msg') -- Error matches pattern
```

### Assertion Mapping (Busted → mini.test)

| Busted (assert.\*)          | mini.test (expect.\*)          |
| --------------------------- | ------------------------------ |
| `assert.are.equal(a, b)`    | `expect.equality(a, b)`        |
| `assert.are.same(a, b)`     | `expect.equality(a, b)` (deep) |
| `assert.is_true(v)`         | `expect.equality(v, true)`     |
| `assert.is_false(v)`        | `expect.equality(v, false)`    |
| `assert.is_nil(v)`          | `expect.equality(v, nil)`      |
| `assert.is_not_nil(v)`      | `expect.no_equality(v, nil)`   |
| `assert.are_not.equal(a,b)` | `expect.no_equality(a, b)`     |
| `assert.has_error(fn)`      | `expect.error(fn)`             |
| `assert.has_error(fn, msg)` | `expect.error(fn, msg)`        |

## Spy/Stub Utilities

mini.test doesn't include luassert's spy/stub functionality. Use the provided
helper module:

```lua
local spy = require('tests.helpers.spy')
```

### Creating Spies

```lua
-- Create a standalone spy
local callback_spy = spy.new(function() end)

-- Pass spy as callback (type cast for luals)
some_function(callback_spy --[[@as function]])

-- Check call count
expect.equality(callback_spy.call_count, 1)

-- Check if called with specific arguments
expect.equality(callback_spy:called_with('arg1', 'arg2'), true)

-- Get arguments from specific call
local args = callback_spy:call(1)  -- First call arguments
```

### Spying on Existing Methods

```lua
-- Create spy on existing method
local feedkeys_spy = spy.on(vim.api, 'nvim_feedkeys')

-- Method still works, but calls are tracked
vim.api.nvim_feedkeys('keys', 'n', false)

-- Check calls
expect.equality(feedkeys_spy.call_count, 1)
expect.equality(feedkeys_spy:called_with('keys', 'n', false), true)

-- IMPORTANT: Always revert in after_each
feedkeys_spy:revert()
```

### Creating Stubs

```lua
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

-- Check calls
expect.equality(fs_stat_stub.call_count, 1)

-- IMPORTANT: Always revert in after_each
fs_stat_stub:revert()
```

### Spy/Stub Best Practices

```lua
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
    expect.equality(my_stub.call_count, 1)
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
    expect.equality(transport_stub.call_count, 1)
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

**Best practices:**

```lua
describe("MyModule", function()
  local bufnr
  local my_stub

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    my_stub = spy.stub(vim.uv, 'fs_stat')
  end)

  after_each(function()
    -- CRITICAL: Clean up resources
    my_stub:revert()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("does something", function()
    -- Test uses fresh buffer and stub
  end)
end)
```

### Multi-Tabpage Testing

Since agentic.nvim supports **one instance per tabpage**, tests must verify:

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
local MiniTest = require('mini.test')
local expect = MiniTest.expect
local child = new_child()  -- Global helper from tests/init.lua

describe('integration', function()
  setup(function()
    child.setup()  -- Bootstraps lazy.nvim with plugin
  end)

  teardown(function()
    child.stop()
  end)

  before_each(function()
    child.cmd('enew')
  end)

  it('loads plugin correctly', function()
    local loaded = child.lua_get([[package.loaded['agentic'] ~= nil]])
    expect.equality(loaded, true)
  end)
end)
```

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

- [mini.test Documentation](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md)
- [mini.test Help](https://github.com/echasnovski/mini.nvim/blob/main/doc/mini-test.txt)
