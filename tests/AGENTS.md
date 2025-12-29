# Testing Guide for agentic.nvim

## Testing Framework Decision

**Framework:** Busted with lazy.nvim's `minit.busted()`

**Why:**

- Industry standard for Neovim plugins
- Standalone CLI command (no Makefile wrapper needed)
- Automatic setup via lazy.nvim (installs busted, hererocks, nlua)
- Better CI integration (just run the test command)
- Encouraged by Folke and lazy.nvim ecosystem

**Rejected alternatives:**

- **Plenary:** Requires Makefile wrapper, less standard CLI
- **mini.test:** Excessive complexity (child process management, custom syntax)

## Test File Organization

**Location:** Co-located with source files in `lua/` directory

**Pattern:** `<module>_spec.lua` next to `<module>.lua`

**Example structure:**

```
lua/agentic/
  ├── init.lua
  ├── init_spec.lua
  ├── session_manager.lua
  ├── session_manager_spec.lua
  └── utils/
      ├── logger.lua
      └── logger_spec.lua
```

**Why co-located:**

- Easy to find related test
- Clear coupling between code and tests
- Repository cloned anyway (tests/ doesn't save space)
- Better developer experience for navigation

**Note:** `tests/` directory still exists and contains:

- `tests/busted.lua` - Test runner
- `tests/unit/` - Legacy/shared test files (if needed)

## Running Tests

### Basic Usage

```bash
# Run all tests
nvim -l tests/busted.lua lua/ tests/

# Run specific test file
nvim -l tests/busted.lua lua/agentic/acp/agent_modes_spec.lua

# Inspect test environment
nvim -u tests/busted.lua
```

### First Run

First run will be slower as it downloads and installs:

- busted testing framework
- hererocks (Lua version manager)
- nlua (Neovim Lua CLI adapter)

Everything installs in `lazy_repro/` directory (gitignored, isolated).

Subsequent runs are fast.

## Test Structure

### Basic Test Pattern

```lua
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
    assert.equals('expected', result)
  end)

  it('handles errors', function()
    assert.has_error(function()
      MyModule.function_name(nil)
    end)
  end)
end)
```

### Assertions

**IMPORTANT:** Busted assertions do not accept an optional second argument for
custom error messages, and LuaCATS type definitions don't include it also. To
avoid `redundant-parameter` warnings don't use the second argument.

```lua
-- Equality (use assert.equal, NOT assert.equals)
assert.equal(expected, actual)  -- ✅ Preferred: no message
assert.same(expected_table, actual_table)  -- Deep equality

-- ❌ AVOID: Custom messages cause LuaLS warnings
assert.equal(expected, actual, "Custom error message")  -- Warning: redundant-parameter

-- Truthiness
assert.is_true(value)
assert.is_false(value)
assert.is_nil(value)
assert.is_not_nil(value)

-- Errors
assert.has_error(function() ... end)
assert.has_no_errors(function() ... end)

-- Types
assert.is_function(value)
assert.is_table(value)
assert.is_string(value)
assert.is_number(value)

-- ❌ AVOID: All of these cause redundant-parameter warnings
assert.is_true(value, "Custom message")
assert.is_not_nil(value, "Should not be nil")
assert.has_error(function() ... end, "Should throw error")
```

## Mocking Dependencies

### Complete Module Mocking

```lua
local mock = require('luassert.mock')

describe('with mocked vim.api', function()
  local api_mock

  before_each(function()
    api_mock = mock(vim.api, true)
    api_mock.nvim_command.returns(nil)
    api_mock.nvim_get_current_buf.returns(1)
  end)

  after_each(function()
    mock.revert(api_mock)
  end)

  it('calls API correctly', function()
    local MyModule = require('agentic.mymodule')
    MyModule.do_something()
    assert.stub(api_mock.nvim_command).was_called_with('echo "test"')
  end)
end)
```

### Function Stubbing

```lua
local stub = require('luassert.stub')

describe('with stubbed functions', function()
  local my_stub

  before_each(function()
    my_stub = stub(vim.api, 'nvim_buf_set_lines')
  end)

  after_each(function()
    my_stub:revert()
  end)

  it('uses stubbed function', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {'line'})
    -- Type-safe assertion syntax
    assert.stub(my_stub).was.called(1)
  end)
end)
```

### Spies

```lua
local spy = require('luassert.spy')

describe('with spies', function()
  it('tracks function calls', function()
    local s = spy.on(vim.api, 'nvim_command')
    vim.api.nvim_command('echo "test"')

    -- Type-safe assertion syntax
    assert.spy(s).was.called(1)
    assert.spy(s).was.called_with('echo "test"')

    s:revert()
  end)

  it('creates spy callbacks', function()
    local callback_spy = spy.new(function(arg) end)

    -- Pass spy as function (requires type cast for luals)
    some_function(callback_spy --[[@as function]])

    -- Assert spy was called
    assert.spy(callback_spy).was.called(1)
    assert.spy(callback_spy).was.called_with('expected_arg')
  end)
end)
```

### Type-Safe Spy/Stub Assertions

The luassert type definitions provide spy/stub assertions through the `was`
table:

```lua
-- ✅ CORRECT - Methods exist via `was` table
assert.spy(my_spy).was.called(0)        -- Not called (pass 0 as count)
assert.spy(my_spy).was.called(1)        -- Called once
assert.spy(my_spy).was.called(2)        -- Called twice
assert.spy(my_spy).was.called_with(arg) -- Called with specific arg
assert.stub(my_stub).was.called(1)      -- Stub called once

-- ✅ Other available assertions via `was` table
assert.spy(my_spy).was.called_at_least(2)  -- Called at least N times
assert.spy(my_spy).was.called_at_most(3)   -- Called at most N times
assert.spy(my_spy).was.returned_with(val)  -- Returned specific value

-- ❌ WRONG - These method names don't exist
assert.spy(my_spy).was_called()         -- No `was_called` method
assert.spy(my_spy).was_not_called()     -- No `was_not_called` method
assert.spy(my_spy).was_called_with(arg) -- No `was_called_with` method
```

**Key insight:** At runtime, both `was.called()` and `was_called()` work due to
luassert's `__index` metatable magic that splits underscores into tokens.
However, LuaLS type definitions only document the `was.called()` pattern (via
the `was` table) because type systems can't express this dynamic behavior. **Use
`was.called()` to satisfy type checking.**

Use `was.called(0)` to assert a spy was not called.

## Test Types

### Unit Tests

- Test individual functions/modules in isolation
- Heavy use of mocks/stubs
- Fast execution
- Located next to source: `<module>_spec.lua`

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
the transport layer to avoid exposing API tokens.

**Example:**

```lua
local stub = require('luassert.stub')

describe('ACP provider', function()
  local transport_stub

  before_each(function()
    local transport = require('agentic.acp.transport')
    transport_stub = stub(transport, 'send')
    transport_stub.returns({
      type = 'message',
      content = 'mocked response',
    })
  end)

  after_each(function()
    transport_stub:revert()
  end)

  it('sends messages without real API calls', function()
    local provider = require('agentic.acp.provider').new({
      command = 'claude-code-acp',
    })

    local response = provider:send_prompt('test')

    assert.is_not_nil(response)
    assert.stub(transport_stub).was_called()
    -- No actual API calls made, no tokens exposed
  end)
end)
```

---

## Important Notes

### Neovim API Access

- **nlua provides 100% Neovim API access** - it's just a wrapper around
  `nvim -l`
- Both Plenary and Busted with nlua use the same Neovim runtime

### Test Isolation and Execution Model

**🚨 CRITICAL: Understanding Busted's Execution Model**

**Tests run sequentially in a single Neovim process:**

- ✅ Tests execute **one after another** (not in parallel)
- ⚠️ All tests share the **same Neovim instance**
- ⚠️ Tests **CAN affect each other** through shared global state
- ⚠️ Module caching means `require()` returns the same module instance across
  tests
- ⚠️ Neovim APIs operate on the same editor state (buffers, windows,
  autocommands, etc.)

**Critical implications:**

1. **Always clean up resources** - Buffers, windows, autocommands, and timers
   left behind will affect subsequent tests
2. **Module-level state persists** - Any module-level variables retain their
   values between tests
3. **Global Neovim state persists** - Vim variables, options, and global state
   carry over
4. **Treesitter parsers cache** - Parser state may persist between tests

**Best practices:**

```lua
describe("MyModule", function()
  local bufnr

  before_each(function()
    -- Create fresh resources for each test
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    -- CRITICAL: Clean up resources
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("does something", function()
    -- Test uses fresh buffer
  end)
end)
```

**Test environment:**

- Tests run in isolated `lazy_repro/` directory (gitignored)
- Use `vim.env.LAZY_STDPATH = "lazy_repro"` for test runner (already set in
  `busted.lua` and `repro.lua`)
- Each test should be independent (use `before_each`/`after_each`)

### Multi-Tabpage Testing

Since agentic.nvim supports **one instance per tabpage**, tests must verify:

- Tabpage isolation (no cross-contamination)
- Independent state per tabpage
- Proper cleanup when tabpage closes

Example:

```lua
it('maintains separate state per tabpage', function()
  -- Test tabpage isolation
  local tab1 = vim.api.nvim_get_current_tabpage()

  require('agentic').toggle()

  vim.cmd('tabnew')
  local tab2 = vim.api.nvim_get_current_tabpage()

  require('agentic').toggle()

  -- Verify both tabpages have independent sessions
  -- Add assertions here
end)
```

## Debugging Tests

### Verbose Output

```bash
# Run with verbose output
BUSTED_ARGS="--verbose" nvim -l tests/busted.lua lua/
```

### Debug Specific Test

```bash
# Run single test file
nvim -l tests/busted.lua lua/agentic/init_spec.lua
```

### Inspect Test Environment

```bash
# Open Neovim with test environment loaded
nvim -u tests/busted.lua

# Then manually run tests
:lua require('plenary.busted').run('lua/agentic/init_spec.lua')
```

## Resources

- [lazy.nvim Developers Documentation](https://lazy.folke.io/developers)
- [Testing Neovim Plugins with Busted](https://hiphish.github.io/blog/2024/01/29/testing-neovim-plugins-with-busted/)
- [LuaRocks Testing Guide](https://mrcjkb.dev/posts/2023-06-06-luarocks-test.html)
- [Busted Documentation](https://lunarmodules.github.io/busted/)
