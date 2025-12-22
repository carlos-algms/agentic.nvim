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
nvim -l ./tests/busted.lua lua/

# Or make it executable
./tests/busted.lua lua/

# Inspect test environment
nvim -u ./tests/busted.lua
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

```lua
-- Equality
assert.equals(expected, actual)
assert.same(expected_table, actual_table)  -- Deep equality

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
  before_each(function()
    stub(vim.api, 'nvim_buf_set_lines')
  end)

  after_each(function()
    vim.api.nvim_buf_set_lines:revert()
  end)

  it('uses stubbed function', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {'line'})
    assert.stub(vim.api.nvim_buf_set_lines).was_called()
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
    assert.spy(s).was_called()
    assert.spy(s).was_called_with('echo "test"')
  end)
end)
```

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

### Test Isolation

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
BUSTED_ARGS="--verbose" nvim -l ./tests/busted.lua lua/
```

### Debug Specific Test

```bash
# Run single test file
nvim -l ./tests/busted.lua lua/agentic/init_spec.lua
```

### Inspect Test Environment

```bash
# Open Neovim with test environment loaded
nvim -u ./tests/busted.lua

# Then manually run tests
:lua require('plenary.busted').run('lua/agentic/init_spec.lua')
```

## Resources

- [lazy.nvim Developers Documentation](https://lazy.folke.io/developers)
- [Testing Neovim Plugins with Busted](https://hiphish.github.io/blog/2024/01/29/testing-neovim-plugins-with-busted/)
- [LuaRocks Testing Guide](https://mrcjkb.dev/posts/2023-06-06-luarocks-test.html)
- [Busted Documentation](https://lunarmodules.github.io/busted/)

