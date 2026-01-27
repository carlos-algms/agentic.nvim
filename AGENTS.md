# Agents Guide

**agentic.nvim** is a Neovim plugin that emulates Cursor AI IDE behavior,
providing AI-driven code assistance through a chat interface for interactive
conversations, code generation, and permission approvals.

## 📋 Documentation Scope

**When to add documentation:**

- Module introduces new architectural pattern
- Utility used across multiple components
- Violating pattern breaks core functionality
- Non-obvious tabpage isolation requirements

Read code for implementation details. This guide prevents architectural
mistakes, not duplicates what's clear in code.

## 🚨 CRITICAL: No Assumptions - Gather Context First

**NEVER make assumptions. ALWAYS gather context before decisions or
suggestions.**

### Mandatory Context Gathering

Before implementing, suggesting, or answering:

1. **Read relevant files** - Don't guess implementation details
2. **Search codebase** - Find existing patterns and usage
3. **Check dependencies** - Understand what relies on what
4. **Verify types** - Read type definitions, don't assume structure

### Examples of Forbidden Assumptions

❌ **DON'T:**

- "This probably uses X pattern"
- "I assume this field exists"
- "This likely works like Y"
- "Based on similar projects..."

✅ **DO:**

- Read files to understand current implementation
- Search for usage patterns across codebase
- Verify types and interfaces before using them
- Build complete context before suggesting solutions

### Incomplete Solutions Are Unacceptable

- Don't suggest partial implementations expecting me to fill gaps
- Don't provide solutions with "you might need to..." suggestions
- Don't guess parameter types or return values, read the files and find
  implementation
- If missing context, gather it first - don't ask user

**CRITICAL:** If you haven't read the relevant code, you don't have enough
context to make decisions or suggestions!

## 🚨 CRITICAL: Multi-Tabpage Architecture

**EVERY FEATURE MUST BE MULTI-TAB SAFE** - This plugin supports **one session
instance per tabpage**.

### Architecture Overview

- **Tabpage instance control:** `SessionRegistry` manages instances via
  `sessions` table mapping `tab_page_id -> SessionManager`
- **1 ACP provider instance** (single subprocess per provider) shared across all
  tabpages (managed by `AgentInstance`)
- **1 ACP session ID per tabpage** - The ACP protocol supports multiple sessions
  per instance, but only one session is active at a time per tabpage
- **1 SessionManager + 1 ChatWidget per tabpage** - Full UI isolation between
  tabpages

Each tabpage has independent:

- ACP session ID (tracked by the shared provider)
- Chat widget (buffers, windows, state)
- Status animation
- Permission manager
- File list
- Code selection
- All UI state and resources

### Implementation Requirements

When implementing ANY feature:

- **NEVER use module-level shared state** for per-tabpage runtime data
  - ❌ `local current_session = nil` (single session for all tabs)
  - ✅ Store per-tabpage state in tabpage-scoped instances
  - ✅ Module-level constants OK for truly global config: `local CONFIG = {}`

- **Namespaces are GLOBAL but extmarks are BUFFER-SCOPED**
  - ✅ `local NS_ID = vim.api.nvim_create_namespace("agentic_animation")` -
    Module-level OK
  - ✅ Namespaces can be shared across tabpages safely
  - **Why:** Extmarks are stored per-buffer, and each tabpage has its own
    buffers
  - **Key insight:** `nvim_create_namespace()` is idempotent (same name = same
    ID globally)
  - **Clearing extmarks:** Use
    `vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, end_line)`
  - **Pattern:** Module-level namespace constants are fine - isolation comes
    from buffer separation
  - **Example:**

    ```lua
    -- Module level (shared namespace ID is OK)
    local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

    -- Instance level (each instance has its own buffer)
    function Animation:new(bufnr)
        return { bufnr = bufnr }
    end

    -- Operations are buffer-specific using module-level namespace
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_ANIMATION, ...)
    vim.api.nvim_buf_clear_namespace(self.bufnr, NS_ANIMATION, 0, -1)
    ```

- **Highlight groups are GLOBAL** (shared across all tabpages)
  - ✅ `vim.api.nvim_set_hl(0, "AgenticTitle", {...})` - Defined once in
    `lua/agentic/theme.lua`
  - Highlight groups apply globally to all buffers/windows/tabpages
  - Theme setup runs once during plugin initialization
  - Use namespaces to control WHERE highlights appear, not to isolate highlight
    definitions

- **Scoped storage:** Use correct accessor for the use case

  | Scope   | Accessor         | Purpose          | Use For         | Example                          |
  | ------- | ---------------- | ---------------- | --------------- | -------------------------------- |
  | Buffer  | `vim.b[bufnr]`   | Custom variables | User data/state | `vim.b[bufnr].my_state = {}`     |
  | Buffer  | `vim.bo[bufnr]`  | Built-in options | Neovim settings | `vim.bo[bufnr].filetype = "lua"` |
  | Window  | `vim.w[winid]`   | Custom variables | User data/state | `vim.w[winid].my_state = {}`     |
  | Window  | `vim.wo[winid]`  | Built-in options | Neovim settings | `vim.wo[winid].number = true`    |
  | Tabpage | `vim.t[tabpage]` | Custom variables | User data/state | `vim.t[tabpage].my_state = {}`   |

  **Notes:**
  - `vim.b` stores buffer-local variables (equivalent to Vimscript `b:`
    variables)
  - `vim.bo` sets buffer options (equivalent to `:setlocal`)
  - `vim.w` stores window-local variables (equivalent to Vimscript `w:`
    variables)
  - `vim.wo` sets window options
  - `vim.t` stores tabpage-local variables (equivalent to Vimscript `t:`
    variables)
  - State stored in scoped storage is automatically cleaned up when the scope is
    deleted
  - Invalid option names in option accessors (`vim.bo`, `vim.wo`) throw errors

- **Get tabpage ID correctly**
  - In instance methods with `self.tab_page_id`
  - From buffer: `vim.api.nvim_win_get_tabpage(vim.fn.bufwinid(bufnr))`
  - Current tabpage: `vim.api.nvim_get_current_tabpage()`

- **Buffers/windows are tabpage-specific**
  - Each tabpage manages its own buffers and windows
  - Never assume buffer/window exists globally
  - Use `vim.api.nvim_tabpage_*` APIs when needed

- **Autocommands must be tabpage-aware**
  - Prefer buffer-local: `vim.api.nvim_create_autocmd(..., { buffer = bufnr })`
  - Filter by tabpage in global autocommands if necessary

- **Keymaps must be buffer-local**
  - Always use: `BufHelpers.keymap_set(bufnr, "n", "key", fn)`
  - NEVER use global keymaps that affect all tabpages

### Class Design Guidelines: creating and modifying

- **Minimize class properties** - Only include properties that:
  - Are accessed by external code (other modules/classes)
  - Are part of the public API
  - Need to be accessed by subclasses

- **Use visibility prefixes for encapsulation** - Control what external code can
  access:

  **Visibility levels (configured in `.luarc.json`):**
  - `_*`: **Private** - Hidden from external consumers (applies to class
    methods/fields ONLY)
  - `__*`: **Protected** - Visible to subclasses
  - No prefix: **Public** - Visible everywhere

  **IMPORTANT:** Module-level local functions and variables do NOT need `_`
  prefix:
  - ✅ `local function helper()` - correct (already private by `local` scope)
  - ❌ `local function _helper()` - incorrect (redundant `_` prefix)
  - ✅ `local config = {}` - correct
  - ❌ `local _config = {}` - incorrect (redundant `_` prefix)
  - ✅ `function MyClass:_private_method()` - correct (class method needs `_`)
  - ✅ `@field _private_field` - correct (class field needs `_`)

  ```lua
  -- ❌ Bad: Unnecessary public exposure of `counter` property, not used externally
  --- @class MyClass
  --- @field counter number
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({ counter = 0 }, self)
  end

  -- ✅ Good: Proper visibility control
  --- @class MyClass
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({
        -- Counter is internal state, not exposed publicly
        _counter = 0
      }, self)
  end

  --- @protected
  function MyClass:__protected_method()
      self._counter = self._counter + 1
  end

  --- Module-level helper functions (no underscore prefix needed)
  local function format_value(val)
      return tostring(val)
  end

  --- @class Child : MyClass
  function Child:use_parent_state()
      self:__protected_method()
  end
  ```

  **Note:** The `@private` annotation is NOT necessary for private class methods
  - LuaLS infers privacy from the `_` prefix automatically
  - Only use `@protected` for protected methods (`__*`, luals limitation)

- **Document intent with LuaCATS** - Use visibility annotations:

  ```lua
  --- @class MyClass
  --- @field public_field string Public API
  --- @field __protected_field table For subclasses
  --- @field _private_field number Internal only
  ```

- **Regular cleanup** - When adding new code, review class definitions and
  remove:
  - Unused properties
  - Properties that were needed during development but are no longer used
  - Properties that could be local variables instead

## Utility Modules

### Logger (`lua/agentic/utils/logger.lua`)

Debug logging utility controlled by `Config.debug` setting.

**Public Methods:**

- **`Logger.notify(msg, level, opts)`** - Safe wrapper around `vim.notify`
  - Prevents "fast context is active" errors via `vim.schedule`
  - Falls back to `print()` if `vim.notify` fails
  - **Default level:** `vim.log.levels.WARN`
  - **ALWAYS use this instead of `vim.notify` directly**
  - Signature:
    `Logger.notify(msg: string, level?: vim.log.levels, opts?: table)`
  - Examples:
    - `Logger.notify("Session created")` - Uses default WARN level
    - `Logger.notify("Session created", vim.log.levels.INFO)` - Explicit level

- **`Logger.debug(...)`** - Print debug messages that can be retrieved with the
  command `:messages`
  - Only outputs when `Config.debug = true`
  - Accepts multiple arguments (strings or tables)
  - Automatically includes timestamp, caller module, and line number
  - Tables are formatted with `vim.inspect()`
  - Example: `Logger.debug("Session created", session_id)`

- **`Logger.debug_to_file(...)`** - Append debug messages to log file
  - Only writes when `Config.debug = true`
  - Log file location: `~/.cache/nvim/agentic_debug.log` (macOS/Linux)
  - Same formatting as `Logger.debug()`
  - Example: `Logger.debug_to_file("Complex state:", state_table)`

**Important Notes:**

- 🚨 **NEVER use `vim.notify` directly** - Always use `Logger.notify` to avoid
  fast context errors
- ⚠️ Logger only has `debug()`, `debug_to_file()`, and `notify()` methods - no
  `warn()`, `error()`, or `info()` methods
- Logger.debug() and Logger.debug_to_file() output is conditional on
  `Config.debug` setting

## Code Style

### Lua Class Pattern

**Basic class structure:**

```lua
--- @class Animal
local Animal = {}
Animal.__index = Animal

function Animal:new()
    self = setmetatable({}, self)
    return self
end

function Animal:move()
    print("Animal moves")
end
```

**Key points:**

- Set `__index` to `self` for inheritance
- Use `setmetatable` to create instances
- Return the instance from constructor

**Method definition syntax:**

- `function Class:method()` - Instance method, receives `self` implicitly
  - Called as: `instance:method()` or `instance.method(instance)`
  - Use for methods that need access to instance state

- `function Class.method()` - Module function, static, does NOT receive `self`
  - Called as: `Class.method()` or `instance.method()` (both work, but no
    `self`)
  - Use for utility functions, constructors, or static helpers

#### Inheritance Pattern

**Class setup (module-level):**

```lua
local Parent = {}
Parent.__index = Parent

--- @class Child : Parent
local Child = setmetatable({}, { __index = Parent })
Child.__index = Child
```

**Constructor with parent initialization:**

```lua
function Parent:new(name)
    local instance = {
        name = name,
        parent_state = {}
    }
    return setmetatable(instance, self)
end

function Child:new(name, extra)
    -- Call parent constructor with Parent class
    local instance = Parent.new(Parent, name)

    -- Add child-specific state
    instance.child_state = extra

    -- Re-metatable to child class for proper inheritance chain
    return setmetatable(instance, Child)
end
```

**Critical rules:**

- **Always pass parent class explicitly:** `Parent.new(Parent, ...)` not
  `Parent.new(self, ...)`
- **Re-assign metatable to child class** after parent initialization
- **Inheritance chain:** `instance → Child → Parent`

**Calling parent methods:**

```lua
function Child:move()
    Parent.move(self)  -- Explicit parent method call
    print("Child-specific movement")
end
```

### LuaCATS Annotations

Use consistent formatting for LuaCATS annotations with a space after `---`:

```lua
--- Brief description of the class
--- @class MyClass
--- @field public_field string Public API field
--- @field _private_field number Private implementation detail
local MyClass = {}
MyClass.__index = MyClass

--- Creates a new instance of MyClass
--- @param name string
--- @param options table|nil
--- @return MyClass instance
function MyClass:new(name, options)
    return setmetatable({ public_field = name }, self)
end

--- Performs an operation and returns success status
--- @return boolean success
function MyClass:do_something()
    return true
end
```

**Guidelines:**

- Always include a space after `---` for both descriptions and annotations
- Use `@private` or `@protected` for internal implementation details
- Do NOT provide meaningful parameter and return descriptions, unless requested

- **Return annotation format:** Use `@return {type} return_name description`
  format:
  - ✅ **CORRECT:** `@return boolean success Whether the operation succeeded`
  - ✅ **CORRECT:**
    `@return string|nil result The result if successful, nil otherwise`
  - ❌ **WRONG:** `@return boolean Whether the operation succeeded` - Missing
    return name
  - ❌ **WRONG:** `@return success boolean` - Wrong order (type must come first)

- **Optional types:** Format depends on annotation type

  **`@param` annotations - MUST use explicit `type|nil` union:**
  - ✅ **CORRECT:** `@param winid number|nil` - Explicit union type required
  - ✅ **CORRECT:** `@param options table|nil` - Optional parameter
  - ❌ **WRONG:** `@param winid? number` - LuaLS doesn't properly validate
    optional syntax
  - ❌ **WRONG:** `@param winid number?` - Wrong syntax
  - **Reason:** Due to
    [LuaLS limitation](https://github.com/LuaLS/lua-language-server/issues/2385),
    optional `?` syntax is not properly validated for function parameters, so
    explicit `|nil` union must be used
  - **Note:** Function type parameters also use `|nil`:
    - ✅ **CORRECT:** `@param callback fun(result: table|nil)` - Explicit union
      required
    - ❌ **WRONG:** `@param callback fun(result?: table)` - LuaLS doesn't
      validate this

  **`@field` annotations - Use `variable? type` format:**
  - ✅ **CORRECT:** `@field _state? string` - `?` goes AFTER the variable name
  - ✅ **CORRECT:** `@field diff? { all?: boolean }` - Inline table fields also
    support optional `?`
  - ❌ **WRONG:** `@field _state string|nil` - Use `variable? type` instead
  - ❌ **WRONG:** `@field _state string?` - `?` must be after variable name, not
    type

  **`@return`, `@type`, and `@alias` annotations - Use explicit `type|nil`
  union:**
  - ✅ **CORRECT:** `@return string|nil result` - Explicit union type
  - ✅ **CORRECT:** `@type table<string, number|nil>` - Explicit union type
  - ✅ **CORRECT:** `@alias MyType string|nil` - Explicit union type
  - ❌ **WRONG:** `@return string? result` - Do NOT use `?` after type
  - ❌ **WRONG:** `@type table<string, number?>` - Do NOT use `?` after type
  - ❌ **WRONG:** `@alias MyType string?` - Do NOT use `?` after type
  - **Reason:** Makes the optional nature more explicit in type definitions

  **`fun()` type declarations - Use explicit `type|nil` union:**
  - ✅ **CORRECT:** `fun(result: table|nil)` - Explicit union type (required due
    to
    [LuaLS limitation](https://github.com/LuaLS/lua-language-server/issues/2385))
  - ❌ **WRONG:** `fun(result?: table)` - Optional syntax ignored in `fun()`
    declarations, luals ignores it and don't run null checks properly
  - **Note:** `@param` and `@field` annotations can use `variable? type`, but
    inline `fun()` parameters must use `type|nil`

- **Typed variables before return:** When returning complex types (tables,
  arrays, custom classes), use a typed intermediate variable instead of
  returning directly. LuaLS cannot infer types from inline return statements.

  ```lua
  -- ❌ Bad: LuaLS cannot infer the return type
  function M.create_block(lines)
      return {
          start_line = 1,
          end_line = #lines,
          content = lines,
      }
  end

  -- ✅ Good: Type annotation enables proper type checking
  --- @return MyModule.Block block
  function M.create_block(lines)
      --- @type MyModule.Block
      local block = {
          start_line = 1,
          end_line = #lines,
          content = lines,
      }
      return block
  end
  ```

- Do NOT provide meaningful parameter and return descriptions, unless requested
- Group related annotations together (class fields, function params, returns)

## Development & Linting

### Agentic.nvim Plugin Requirements

- Neovim v0.11.0+ (make sure settings, functions, and APIs, specially around
  `vim.*` are for this version or newer)
- LuaJIT 2.1 (bundled with Neovim, based on Lua 5.1)
  - Be ultra careful with lua features and neovim APIs based on version
- Optional: https://github.com/hakonharnes/img-clip.nvim for Screenshot pasting
  from the clipboard (drag-and-drop works without it, it's terminal feature, not
  plugin, neither neovim specific)

### 🚨 MANDATORY: Post-Change Validation for Lua Files

**ALWAYS run all validations after making ANY Lua file changes:**

```bash
make validate
```

This single command runs:

- `make format` - Format all Lua files
- `make luals` - Type checking
- `make luacheck` - Linting
- `make test` - All tests

**Why use `make validate`:**

- Validations are fast (< 5 seconds combined)
- Single permission prompt for all checks
- Ensures all checks pass together
- Output redirected to log files automatically

**Output format (exactly 5-6 lines):**

The `make validate` command outputs **only 5-6 short lines** to stdout. Example:

```bash
format: 0 (took 1s) - log: .local/agentic_format_output.log
luals: 0 (took 2s) - log: .local/agentic_luals_output.log
luacheck: 0 (took 0s) - log: .local/agentic_luacheck_output.log
test: 0 (took 1s) - log: .local/agentic_test_output.log
Total: 4s
```

Each line shows: `{task}: {exit_code} (took {seconds}s) - log: {log_path}`

- Exit code `0` = success, non-zero = failure
- Verbose output is written to log files, NOT stdout

**🚨 FORBIDDEN: Output redirection**

- **NEVER redirect `make validate` output** - it's already minimal (5-6 lines)
- **NEVER use `> file`, `>> file`, `2>&1`, `| tee`, etc.** on `make validate`
- **NEVER use `head`, `tail`, or pipes** on `make validate` output
- The command handles its own log file redirection internally

```bash
# ❌ FORBIDDEN - Don't redirect output
make validate > my_output.log
make validate 2>&1 | tee output.log
make validate | head -20

# ✅ CORRECT - Run directly, read the 5-6 lines output
make validate
```

**CRITICAL: Log file locations (defined by Makefile):**

The `make validate` target writes verbose output to these **exact paths** in the
project root:

- `.local/agentic_format_output.log` - StyLua formatting output
- `.local/agentic_luals_output.log` - LuaLS type checking output
- `.local/agentic_luacheck_output.log` - Luacheck linting output
- `.local/agentic_test_output.log` - Test runner output

**Rules:**

- **NEVER create or write to different log file paths** - always use the paths
  above
- Only read exit codes from `make validate` output unless there's a failure
- If any command fails, read the corresponding log file to diagnose the issue

**Reading log files (only when validation fails):**

- **NEVER use Read tool** - floods context with entire file
- **Use targeted commands instead:**
  - `tail -n 10 .local/agentic_luals_output.log` - Last 10 lines (errors usually
    at end)
  - `rg "error|warning|fail" .local/agentic_test_output.log` - Search for
    specific patterns (smart-case by default)
  - `grep -i "error" .local/agentic_luacheck_output.log` - Search with grep
    (case-insensitive)
- Increase line count only if needed for context
- Read only what's needed to diagnose the issue
- **If multiple reads needed:** Use `cat .local/agentic_*_output.log` once for
  entire file instead of reading multiple chunks (avoids loops of reading trying
  to find info)

### Testing

**See `@tests/AGENTS.md` for complete testing guide.**

### Type Checking

`make luals` runs Lua Language Server headless diagnosis across all files in the
project and provides comprehensive type checking.

### Available Make targets:

- `make luals` - Run Lua Language Server headless diagnosis (type checking) -
  **Use this for full project type checks**
- `make luacheck` - Run Luacheck linter (style and syntax checking)
- `make format` - Format all Lua files with StyLua
- `make format-file FILE=path/to/file.lua` - Format a specific file

**For more targets and implementation details:** Read the `Makefile` at the
project root

### Tool overrides:

Override default tool paths if needed:

```bash
make NVIM=/path/to/nvim luals
make LUALS=/path/to/lua-language-server luals
make LUACHECK=/path/to/luacheck luacheck
```

**Note:** The `lua/agentic/acp/acp_client.lua` file contains critical type
annotations for Lua Language Server support. These annotations should **never**
be removed, only updated when the underlying types change.

### Configuration & User Documentation

#### Config File Changes

The `lua/agentic/config_default.lua` file defines all user-configurable options.

#### Theme & Highlight Groups

The `lua/agentic/theme.lua` file defines all custom highlight groups used by the
plugin.

**IMPORTANT:** When adding new highlight groups:

1. Add the highlight group name to `Theme.HL_GROUPS` constant
2. Define the default highlight in `Theme.setup()` function
3. **Update the README.md** "Customization (Ricing)" section with:
   - The new highlight group in the code example
   - A new row in the "Available Highlight Groups" table

### Provider System

#### ACP Providers (Agent Client Protocol)

These providers spawn **external CLI tools** as subprocesses and communicate via
the Agent Client Protocol:

- **Requirements**: External CLI tools must be installed
  - `npm i -g @zed-industries/claude-code-acp` or
    `brew install --cask claude-code` or
    `curl -fsSL https://claude.ai/install.sh | bash`
  - `npm i -g @google/gemini-cli` or `brew install --cask gemini`
  - `npm i -g @zed-industries/codex-acp` or `brew install --cask codex` or
    download from releases
  - `npm i -g opencode-ai` or `brew install opencode` or
    `curl -fsSL https://opencode.ai/install | bash`
  - `npm i -g @blowmage/cursor-agent-acp`

##### Provider adapters:

Each provider has a dedicated adapter in `lua/agentic/acp/adapters/`:

- `claude_acp_adapter.lua` - Claude Code ACP adapter
- `gemini_acp_adapter.lua` - Gemini ACP adapter
- `codex_acp_adapter.lua` - Codex ACP adapter
- `opencode_acp_adapter.lua` - OpenCode ACP adapter
- `cursor_acp_adapter.lua` - Cursor Agent ACP adapter
- `auggie_acp_adapter.lua` - Auggie ACP adapter

These adapters implement provider-specific message formatting, tool call
handling, and protocol quirks.

**CRITICAL:** When adding a new ACP provider, update this documentation

##### ACP provider configuration:

```lua
acp_providers = {
  ["claude-acp"] = {
    name = "Claude ACP",                   -- Display name
    command = "claude-code-acp",           -- CLI command to spawn
    env = {                                -- Environment variables
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
  ["gemini-acp"] = {
    name = "Gemini ACP",
    command = "gemini",
    args = { "--experimental-acp" },       -- CLI arguments
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
}
```

The ACP documentation can be found at:

- Complete Schema: https://agentclientprotocol.com/protocol/schema.md
- Overview: https://agentclientprotocol.com/protocol/overview.md
- Initialization: https://agentclientprotocol.com/protocol/initialization.md
- Session Setup: https://agentclientprotocol.com/protocol/session-setup.md
- Prompt Turn: https://agentclientprotocol.com/protocol/prompt-turn.md
- Content: https://agentclientprotocol.com/protocol/content.md
- Tool Calls: https://agentclientprotocol.com/protocol/tool-calls
- File System: https://agentclientprotocol.com/protocol/file-system.md
- Terminals: https://agentclientprotocol.com/protocol/terminals.md
- Agent Plan: https://agentclientprotocol.com/protocol/agent-plan.md
- Session Modes: https://agentclientprotocol.com/protocol/session-modes.md
- Slash Commands: https://agentclientprotocol.com/protocol/slash-commands.md
- Extensibility: https://agentclientprotocol.com/protocol/extensibility.md
- Transports: https://agentclientprotocol.com/protocol/transports.md

##### ACP architectural limitations:

- **No partial acceptance of file changes:** Users must accept or reject the
  entire file's changes as a unit. The ACP protocol is async and transactional
  (all-or-nothing tool calls). Implementing partial acceptance would require
  complex workarounds (e.g., auto-accepting then partially reverting) which adds
  significant complexity. This feature is deferred/out of scope.

### Neovim Documentation Files and help docs

**IMPORTANT**: For dealing with neovim native features and APIs, refer to the
official docs.

**CRITICAL**: Do NOT run `nvim --headless` or any other `nvim` command to read
help documentation. Use direct file access instead.

**Why:** Running `nvim` commands can hang, cause race conditions, or interfere
with development environment.

#### Neovim Documentation Lookup Strategy:

Always prefer reading local documentation files directly from the Neovim runtime
path, because they reflect the exact version installed on my system.

Common path patterns after discovery:

- **macOS (Homebrew):**
  - Runtime docs: `/opt/homebrew/Cellar/neovim/*/share/nvim/runtime/doc/`
  - Note: We don't need the exact version, just use the wildcard `*` to match
    the installed version
- **Linux (Snap):** `/snap/nvim/current/usr/bin/nvim`
  - Runtime docs: `/snap/nvim/current/usr/share/nvim/runtime/doc/`

**If local lookup fails:** Use GitHub raw URLs (least preferred)

```
https://raw.githubusercontent.com/neovim/neovim/refs/tags/v<version>/runtime/doc/<doc-name>.txt
```

**Tip:** Do not assume a file contains what you need, use `rg`, or `grep` on the
`runtime/doc` folder to find the file containing needed info.
