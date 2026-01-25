# Project Context

## Purpose

**agentic.nvim** is a Neovim plugin that provides a chat interface for AI coding
assistants through the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

Goals:
- Deliver the same experience as using ACP provider CLIs directly from terminal
- Zero hidden prompts or magic - just a clean chat interface
- Support multiple independent chat sessions (one per tabpage)

## Tech Stack

- **Neovim v0.11.0+** API
- **Lua** (LuaJIT 2.1 bundled with Neovim, based on Lua 5.1)
- **ACP (Agent Client Protocol)** for AI provider communication
- **External CLI tools** spawned as subprocesses (claude-code-acp, gemini, codex-acp, opencode, cursor-agent-acp, auggie)

## Design Principles

### YAGNI (You Aren't Gonna Need It)

Build only what's needed now:

- Don't create features or functions "just in case" we might need them
- Don't add unnecessary abstractions for hypothetical future requirements
- Three similar lines of code is better than a premature helper function
- Delete unused code immediately - no commented-out code blocks
- If a feature isn't explicitly requested, don't build it

### SOLID Principles

Apply where appropriate:

- **Single Responsibility** - Each module/class should have one reason to change
- **Open/Closed** - Open for extension (adapters), closed for modification
- **Liskov Substitution** - Provider adapters must be interchangeable
- **Interface Segregation** - Don't force modules to depend on unused interfaces
- **Dependency Inversion** - Depend on abstractions (e.g., `ACPClient` base class)

### DRY (Don't Repeat Yourself)

Avoid code duplication:

- Extract repeated logic into helper functions
- Use `before_each` / `after_each` in tests for common setup/teardown
- Share utilities across modules when genuinely reusable
- **But:** Don't over-abstract - duplication is better than the wrong abstraction

### Race Conditions in Lua/Neovim

Lua is single-threaded. Within a synchronous function, IDs don't go stale.

**Don't add unnecessary validity checks:**
```lua
-- ❌ Unnecessary - bufnr can't become invalid between these lines
local bufnr = vim.api.nvim_get_current_buf()
if vim.api.nvim_buf_is_valid(bufnr) then  -- pointless check
  vim.api.nvim_buf_set_lines(bufnr, ...)
end

-- ✅ Correct - just use it
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, ...)
```

**When validity checks ARE needed:**
- After `vim.schedule()` or other async callbacks
- After `vim.uv` async operations
- When ID is stored and used later (across function calls)
- When ID comes from external/user input

## Project Conventions

### No Assumptions Policy

**CRITICAL: We do not tolerate assumptions or ambiguous definitions.**

Before implementing, suggesting, or making decisions:

- **Read official documentation** - Local Neovim docs, library docs, protocol specs
- **Research online** - Best practices, how other plugins solve similar problems
- **Examine real-world examples** - Reference implementations, popular plugins
- **Verify APIs exist** - Check the exact Neovim version (v0.11.0+) supports the API

**Forbidden behaviors:**
- "This probably works like X"
- "I assume this field exists"
- "Based on similar projects..." (without actually reading them)
- Guessing parameter types or return values

**Required approach:**
- Read the actual source code
- Consult official documentation
- Test assumptions before committing to an approach
- When uncertain, investigate first - don't ask, research

### Code Style

- **LuaCATS annotations** for type checking (run `make luals`)
- **Luacheck** for linting (run `make luacheck`)
- **StyLua** for formatting (configured in `.stylua.toml`)
- **Visibility prefixes:**
  - `_*` = private (hidden from external consumers)
  - `__*` = protected (visible to subclasses)
  - No prefix = public
- **Optional types format:**
  - `@param`/`@field`: Use `variable? type` (e.g., `@param winid? number`)
  - `@return`/`@type`/`@alias`: Use `type|nil` union (e.g., `@return string|nil`)
  - `fun()` declarations: Use `type|nil` union (e.g., `fun(result: table|nil)`)

### Architecture Patterns

- **Multi-tabpage isolation**: One session instance per tabpage via `SessionRegistry`
- **Single ACP provider instance** shared across all tabpages (managed by `AgentInstance`)
- **Class pattern**: Use `Class.__index = Class` with `setmetatable` for instances
- **Inheritance**: Call `Parent.new(Parent, ...)` explicitly, then re-metatable to child
- **No module-level shared state** for per-tabpage runtime data
- **Namespaces are global, extmarks are buffer-scoped**
- **Buffer-local keymaps only** (never global keymaps)

### Decoupling Through Callbacks

**CRITICAL: Modules should not know about each other unless absolutely necessary.**

**Prefer callbacks over passing class instances:**

```lua
-- ❌ Bad: Module knows about specific class
function ModuleA:new(module_b_instance)
  self.module_b = module_b_instance
  -- Creates tight coupling - ModuleA depends on ModuleB interface
end

-- ✅ Good: Module receives callbacks
function ModuleA:new(on_event_callback, on_action_callback)
  self.on_event = on_event_callback
  self.on_action = on_action_callback
  -- Decoupled - ModuleA doesn't need to know what handles the callback
end
```

**When passing instances IS allowed:**

- **Static modules**: Import and call static functions with appropriate arguments
  ```lua
  local Utils = require("myproject.utils")
  Utils.format("data")  -- ✅ OK - static function call
  ```

- **Callbacks**: Pass instance methods as callbacks (they become black boxes to the receiver)
  ```lua
  module_a:new(function(data) module_b:handle(data) end)  -- ✅ OK - callback hides instance
  ```

**Benefits:**
- Reduces coupling between modules
- Makes dependencies explicit through function signatures
- Easier to test (inject mock callbacks)
- Modules can be used in different contexts without modification

**NOTE:** This is the preferred pattern for NEW code. Do NOT refactor existing code to follow this pattern unless explicitly requested. We are migrating to this strategy gradually.

### Autocommand Best Practices

Always use autocommand groups with `clear = true` to prevent duplicates:

```lua
local group = vim.api.nvim_create_augroup("AgenticSomething", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function() ... end,
})
```

Prefer buffer-local autocommands when possible:
```lua
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer = bufnr,  -- Only triggers for this buffer
  callback = function() ... end,
})
```

### State Management

**Prefer Neovim's scoped storage over local variables for new code.**

Neovim provides automatic cleanup when buffers, windows, or tabpages are deleted:

- `vim.b[bufnr]` - Buffer-local variables (auto-cleaned when buffer is deleted)
- `vim.w[winid]` - Window-local variables (auto-cleaned when window is closed)
- `vim.t[tabpage]` - Tabpage-local variables (auto-cleaned when tab is closed)

**Why this matters:** We don't want to manually track and clean up state. If a buffer, window, or tabpage is deleted, all associated data should be deleted automatically.

**Limitations:** These storages only support primitive values (strings, numbers, booleans) and tables containing primitives. They do **NOT** support:
- Functions / callbacks
- Tables containing functions
- Metatables

**When to use local state instead:**
- Storing callbacks or event handlers
- Complex objects with methods
- Data that needs metatables

**Legacy code:** Some existing code uses local variables and manual cleanup. For new code, prefer `vim.b`/`vim.w`/`vim.t` when the data type allows it.

### Logging

Never use `vim.notify` directly. Use `Logger` module from `lua/agentic/utils/logger.lua`:

- **`Logger.debug(...)`** - For development debugging and error scenarios
  - Only outputs when `Config.debug = true`
  - Output visible via `:messages` (lost after restart)
  - Use for: errors, failures, unexpected states, debugging info

- **`Logger.debug_to_file(...)`** - Persistent debug logging
  - Writes to `~/.cache/nvim/agentic_debug.log`
  - Use for: ACP message exchanges, complex debugging sessions

- **`Logger.notify(msg, level?, opts?)`** - User-facing notifications
  - Safe wrapper around `vim.notify` (prevents "fast context" errors)
  - Use for: recurring/intermittent issues users should see
  - Examples: connection issues, provider unavailable, configuration warnings
  - Default level: `vim.log.levels.WARN`

### Testing Strategy

- **Framework**: mini.test with Busted-style emulation (see `tests/AGENTS.md`)
- **Co-located tests are the PREFERRED option** for unit tests:
  - Pattern: `<module>.test.lua` next to `<module>.lua` in `lua/` directory
  - Example: `lua/agentic/session_manager.test.lua`
- **`tests/` directory** contains:
  - `tests/init.lua` - Test runner bootstrap
  - `tests/helpers/` - Spy/stub utilities, assert module, child process helper
  - `tests/mocks/` - Mock implementations (acp_transport_mock, acp_health_mock)
  - `tests/integration/` - Integration tests requiring multiple components
  - `tests/unit/` - Legacy/shared unit tests (prefer co-located tests)
- **Running tests**:
  - `make test` - Run all tests
  - `make test-file FILE=lua/agentic/acp/agent_modes.test.lua` - Run specific file

**CRITICAL: Test Cleanup**

Tests MUST clean up all resources they create. Failing to do so breaks subsequent tests.

**Always clean up:**
- Spies and stubs (call `:revert()` in `after_each`)
- Created buffers (`vim.api.nvim_buf_delete(bufnr, { force = true })`)
- Created windows (`vim.api.nvim_win_close(winid, true)`)
- Created tabpages
- Autocommands
- Any global state modifications

**Prefer `before_each` / `after_each`:**
```lua
describe('MyModule', function()
  local my_spy

  before_each(function()
    my_spy = spy.on(vim.api, 'some_function')
  end)

  after_each(function()
    my_spy:revert()  -- ALWAYS revert spies
  end)
end)
```

**Avoid code duplication:**
- Use `before_each` / `after_each` for common setup/teardown
- Create module-level helper functions for reusable test utilities
- Share fixtures across tests when appropriate

### Code Validation

**Always validate code after changes** by running:

```bash
make validate
```

This single command runs all three validators (luals, luacheck, test) and:
- Automatically outputs logs to `.local/` directory
- Prints exit codes for each validator

**Expected output (all passing):**
```
luals: 0
luacheck: 0
test: 0
```

**Example output with failures:**
```
luals: 1
luacheck: 0
test: 0
```

**Workflow:**
1. Run `make validate`
2. Check exit codes in output (0 = success, non-zero = failure)
3. **Only if a validator fails**, read its log file:
   - `.local/agentic_luals_output.log` - Type checking errors
   - `.local/agentic_luacheck_output.log` - Linting errors
   - `.local/agentic_test_output.log` - Test failures
4. Use `tail -n 30 <logfile>` or `rg "error|warning" <logfile>` to inspect failures

### Git Workflow

**CRITICAL RULES:**

- **NEVER commit to `main` branch** - All work must be on feature branches
- **No commits or staging without explicit user request**
- **ABSOLUTELY NEVER use `git revert`, `git checkout <file>`, or `git reset` to undo files**
  - Files may have been modified before the agent started working
  - Using these commands will lose ALL changes, not just recent edits
  - Agent must track its own edits and revert manually if needed
- Use `git status`, `git diff`, and `git log` before any git operations
- Stage specific files (avoid `git add -A` or `git add .`)
- Never use force push or skip hooks without explicit request

## UI Layout

**Current implementation:** Widget opens on the **right side** only.

The widget is composed of multiple windows stacked vertically (top to bottom):

1. **Chat window** - Main conversation display (AI responses, tool calls)
2. **Todo list window** - Agent's task list
3. **Code snippets window** - Selected code snippets added to context
4. **Files window** - List of files added to context
5. **Prompt window** - User input (always at the bottom)

**Future layouts** (not yet implemented):
- Left side
- Bottom

**Never supported:** Top layout

## Key Entry Points

When exploring the codebase, start here:

- **`lua/agentic/init.lua`** - Public API exposed to users (`toggle`, `open`, `close`, `add_file`, etc.)
- **`lua/agentic/session_manager.lua`** - Core orchestration: glues widget, agent, and message handling
- **`lua/agentic/session_registry.lua`** - Manages session instances per tabpage (weak map)
- **`lua/agentic/acp/acp_client.lua`** - ACP protocol implementation + **ALL type definitions** (NEVER remove annotations)
- **`lua/agentic/acp/agent_instance.lua`** - Singleton provider instance management
- **`lua/agentic/ui/chat_widget.lua`** - UI window layout and buffer management
- **`lua/agentic/config_default.lua`** - All user-configurable options with types

## Public API

Users interact via `require("agentic")`:

- `toggle()` - Toggle chat sidebar
- `open()` / `close()` - Show/hide sidebar
- `add_selection()` - Add visual selection to context
- `add_file()` - Add current file to context
- `add_selection_or_file_to_context()` - Smart add (selection if exists, else file)
- `new_session()` - Destroy current session, start fresh
- `stop_generation()` - Cancel current AI generation
- `setup(opts)` - Initialize plugin with user config

## Domain Context

### ACP (Agent Client Protocol)

- Documentation: https://agentclientprotocol.com
- Providers spawn as external CLI subprocesses
- Support multiple sessions per provider instance

### Provider Adapters

**Why adapters exist:** Each ACP provider implements the protocol differently. We were forced to create individual adapter classes because providers have:

- Different message formats
- Different message ordering
- Different parameter names (`rawInput` vs `content` vs `locations`)
- Different tool call structures

**What IS normalized across providers:**
- Permission requests (`session/request_permission`)
- Message chunks (`agent_message_chunk`, `agent_thought_chunk`)

**What IS NOT normalized (requires adapter handling):**
- Tool calls (`tool_call`) - structure varies significantly
- Tool call updates (`tool_call_update`) - different content formats
- Edit operations - some use `rawInput.new_string`, others use `content[].newText`
- File paths - some in `rawInput.file_path`, others in `locations[].path`

**Adapter location:** `lua/agentic/acp/adapters/`

**When adding a new provider:**
1. Create new adapter class extending `ACPClient`
2. Override `__handle_session_update` to intercept provider-specific messages
3. Implement `_handle_tool_call` and `_handle_tool_call_update` for that provider's format
4. Handle any permission request quirks (e.g., Gemini sends diff in permission request, not tool_call)

**Examples of provider differences:**
- **Claude**: Uses `rawInput.file_path`, `rawInput.new_string`, `rawInput.old_string`
- **Gemini**: Uses `locations[].path`, `content[].newText`, `content[].oldText`; sends tool call data inside permission request
- **Gemini**: Doesn't send `failed` status on cancel - adapter must synthesize it

**Supported providers:** Claude, Gemini, Codex, OpenCode, Cursor Agent, Auggie

### Other Domain Concepts

- **Permission system**: Interactive approval workflow for AI tool calls
- **Agent modes**: Default, Auto Accept, Plan mode (provider-dependent)

## Error Handling

### Use `pcall` for External/Uncertain Operations

Wrap calls that might fail in `pcall`:
- User-provided callbacks (hooks, config functions)
- JSON encoding/decoding
- File I/O operations
- External process communication

```lua
-- ✅ Protect against user callback errors
local ok, err = pcall(user_callback, data)
if not ok then
  Logger.debug("Callback error:", err)
end
```

### Use `vim.schedule` for Deferred Execution

Required when:
- Inside `vim.uv` callbacks (can't call most Neovim APIs directly)
- Inside fast event contexts (e.g., `on_lines` callbacks)
- When you need to ensure the event loop processes pending events

```lua
-- ✅ Defer Neovim API calls from uv callbacks
vim.uv.fs_stat(path, function(err, stat)
  vim.schedule(function()
    -- Safe to call Neovim APIs here
    vim.api.nvim_buf_set_lines(...)
  end)
end)
```

### Early Returns Over Deep Nesting

Prefer guard clauses, but group related checks together:

```lua
-- ✅ Single guard clause with grouped conditions
function process(data)
  if not data or not data.id or not data.name then
    return
  end
  -- actual logic here
end

-- ❌ Multiple separate returns
function process(data)
  if not data then return end
  if not data.id then return end
  if not data.name then return end
  -- actual logic here
end

-- ❌ Deep nesting
function process(data)
  if data then
    if data.id then
      if data.name then
        -- actual logic here
      end
    end
  end
end
```

## Important Constraints

- **Neovim v0.11.0+** required (verify APIs exist for this version)
- **LuaJIT 2.1** (Lua 5.1 features only)
- **No binary installation**: Plugin doesn't install/manage ACP CLI tools for security
- **No API keys required**: Uses provider's native authentication
- **All features must be multi-tab safe**: Independent state per tabpage

## External Dependencies

- **Required**: One of the supported ACP provider CLIs installed globally
- **Optional**: `img-clip.nvim` for clipboard image pasting
- **Optional**: `pngpaste` (macOS), `xclip`/`wl-clipboard` (Linux) for clipboard images
- **Build tools**: `lua-language-server`, `luacheck`, `stylua`