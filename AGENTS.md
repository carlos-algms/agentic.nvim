# Agents Guide

**agentic.nvim** is a Neovim plugin that emulates Cursor AI IDE behavior,
providing AI-driven code assistance through a chat sidebar for interactive
conversations.

## 📋 Documentation Scope

This guide focuses on **architectural decisions and critical patterns** that
agents must understand to work effectively with this codebase.

**What belongs here:**

- ✅ Multi-tabpage architecture and isolation requirements
- ✅ Class design patterns and inheritance rules
- ✅ Critical utility modules that are frequently used
- ✅ Provider system and adapters
- ✅ Code style conventions and LuaCATS standards
- ✅ Development workflows and configuration protocols

**What does NOT belong here:**

- ❌ Exhaustive documentation of every file, module, or class
- ❌ Implementation details that are self-documenting in code
- ❌ Simple utility functions that have clear names and types
- ❌ UI components unless they demonstrate critical patterns

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

- "This probably uses X pattern" → Read the file
- "I assume this field exists" → Check the type definition
- "This likely works like Y" → Verify in code
- "Based on similar projects..." → Check THIS codebase

✅ **DO:**

- Read files to understand current implementation
- Search for usage patterns across codebase
- Verify types and interfaces before using them
- Build complete context before suggesting solutions

### Incomplete Solutions Are Unacceptable

- Don't suggest partial implementations hoping user fills gaps
- Don't provide solutions with "you might need to..." caveats
- Don't guess at parameter types or return values
- If missing context, gather it first - don't ask user

**Rule:** If you haven't read the relevant code, you don't have enough context
to make decisions.

## 🚨 CRITICAL: Multi-Tabpage Architecture

**EVERY FEATURE MUST BE MULTI-TAB SAFE** - This plugin supports **one instance
per tabpage**.

### Architecture Overview

- **Tabpage instance control:** `SessionRegistry` manages instances via
  `sessions` table mapping `tab_page_id -> SessionManager`
- **1 ACP provider instance** (single subprocess per provider) shared across all
  tabpages (managed by `AgentInstance`)
- **1 ACP session ID per tabpage** - The ACP protocol supports multiple sessions
  per instance
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

1. **NEVER use module-level shared state** for per-tabpage runtime data
   - ❌ `local current_session = nil` (single session for all tabs)
   - ✅ Store per-tabpage state in tabpage-scoped instances
   - ✅ Module-level constants OK for truly global config: `local CONFIG = {}`

2. **Namespaces are GLOBAL but extmarks are BUFFER-SCOPED**
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

3. **Highlight groups are GLOBAL** (shared across all tabpages)
   - ✅ `vim.api.nvim_set_hl(0, "AgenticTitle", {...})` - Defined once in
     `lua/agentic/theme.lua`
   - Highlight groups apply globally to all buffers/windows/tabpages
   - Theme setup runs once during plugin initialization
   - Use namespaces to control WHERE highlights appear, not to isolate highlight
     definitions

4. **Get tabpage ID correctly**
   - In instance methods with `self.tab_page_id`
   - From buffer: `vim.api.nvim_win_get_tabpage(vim.fn.bufwinid(bufnr))`
   - Current tabpage: `vim.api.nvim_get_current_tabpage()`

5. **ACP sessions are per-tabpage**
   - Each tabpage gets its own session ID from the shared ACP provider
   - Session state tracked independently per tabpage via `SessionManager`
   - Never mix session IDs between tabpages

6. **Buffers/windows are tabpage-specific**
   - Each tabpage manages its own buffers and windows
   - Never assume buffer/window exists globally
   - Use `vim.api.nvim_tabpage_*` APIs when needed

7. **Autocommands must be tabpage-aware**
   - Prefer buffer-local: `vim.api.nvim_create_autocmd(..., { buffer = bufnr })`
   - Filter by tabpage in global autocommands if necessary

8. **Keymaps must be buffer-local**
   - Always use: `BufHelpers.keymap_set(bufnr, "n", "key", fn)`
   - NEVER use global keymaps that affect all tabpages

### Testing Multi-Tab Isolation

Verify isolation before submitting:

```vim
:tabnew | AgenticChat    " Tab 2: start chat
:tabprev | AgenticChat   " Tab 1: start chat
" Both must work independently - no cross-contamination
```

### Class Design Guidelines

When creating or modifying classes:

1. **Minimize class properties** - Only include properties that:
   - Are accessed by external code (other modules/classes)
   - Are part of the public API
   - Need to be accessed by subclasses or mixins

2. **Use visibility prefixes for encapsulation** - Control what external code
   can access:

   **Visibility levels (configured in `.luarc.json`):**
   - `_*` → **Private** - Hidden from external consumers
   - `__*` → **Protected** - Visible to subclasses, hidden from external
     consumers
   - No prefix → **Public** - Visible everywhere

   ```lua
   -- ❌ Bad: Unnecessary public exposure
   --- @class MyClass
   --- @field counter number
   local MyClass = {}
   MyClass.__index = MyClass

   function MyClass:new()
       return setmetatable({ counter = 0 }, self)
   end

   -- ✅ Good: Proper visibility control
   --- @class MyClass
   --- @field _counter number
   --- @private
   local MyClass = {}
   MyClass.__index = MyClass

   function MyClass:new()
       return setmetatable({ _counter = 0 }, self)
   end

   --- @class Parent
   --- @field __protected_state table
   --- @protected

   --- @class Child : Parent
   function Child:use_parent_state()
       self:__protected_method()
   end
   ```

3. **Document intent with LuaCATS** - Use visibility annotations:

   ```lua
   --- @class MyClass
   --- @field public_field string Public API
   --- @field __protected_field table For subclasses
   --- @field _private_field number Internal only
   ```

4. **Regular cleanup** - When adding new code, review class definitions and
   remove:
   - Unused properties
   - Properties that were needed during development but are no longer used
   - Properties that could be local variables instead

## Utility Modules

### Logger (`lua/agentic/utils/logger.lua`)

Debug logging utility controlled by `Config.debug` setting.

**Public Methods:**

- **`Logger.get_timestamp()`** - Returns current timestamp string
  (`YYYY-MM-DD HH:MM:SS`)

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
  - Includes separator lines between entries
  - Example: `Logger.debug_to_file("Complex state:", state_table)`

**Important Notes:**

- ⚠️ Logger only has `debug()` and `debug_to_file()` methods - no `warn()`,
  `error()`, or `info()` methods
- All debug output is conditional on `Config.debug` setting

**When adding public methods to utility modules, update AGENTS.md with:**

1. Method signature
2. Brief description
3. Usage example
4. Important notes

## Code Style

### Lua Class Pattern

**Basic class structure:**

```lua
--- @class Animal
local Animal = {}
Animal.__index = Animal

function Animal:new()
    local instance = setmetatable({}, self)
    return instance
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

- `function Class.method()` - Module function, does NOT receive `self`
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

1. **Always pass parent class explicitly:** `Parent.new(Parent, ...)` not
   `Parent.new(self, ...)`
2. **Re-assign metatable to child class** after parent initialization
3. **Inheritance chain:** `instance → Child → Parent`

**Why:**

- Parent constructor needs its own class as `self`
- Parent initializes instance state
- Child re-metatables instance to upgrade it
- Method resolution follows `__index` chain

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
--- @param name string The name parameter
--- @param options table|nil Optional configuration table
--- @return MyClass instance The created instance
function MyClass:new(name, options)
    return setmetatable({ public_field = name }, self)
end

--- Performs an operation and returns success status
--- @return boolean success Whether the operation succeeded
function MyClass:do_something()
    return true
end
```

**Guidelines:**

- Always include a space after `---` for both descriptions and annotations
- Use `@private` or `@package` for internal implementation details
- **Optional types:** Format depends on annotation type

  **`@param` and `@field` annotations - Use `variable? type` format:**
  - ✅ **CORRECT:** `@param winid? number` - `?` goes AFTER the variable name
  - ✅ **CORRECT:** `@field _state? string` - `?` goes AFTER the variable name
  - ✅ **CORRECT:** `@field diff? { all?: boolean }` - Inline table fields also support `?`
  - ❌ **WRONG:** `@param winid number|nil` - Use `variable? type` instead
  - ❌ **WRONG:** `@param winid number?` - `?` must be after variable name, not
    type
  - ❌ **WRONG:** `@field _state string|nil` - Use `variable? type` instead
  - ❌ **WRONG:** `@field _state string?` - `?` must be after variable name, not
    type

  **`@return`, `@type`, and `@alias` annotations - Use explicit `type|nil`
  union:**
  - ✅ **CORRECT:** `@return string|nil` - Explicit union type
  - ✅ **CORRECT:** `@type table<string, number|nil>` - Explicit union type
  - ✅ **CORRECT:** `@alias MyType string|nil` - Explicit union type
  - ❌ **WRONG:** `@return string?` - Do NOT use `?` after type
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

- Do NOT provide meaningful parameter and return descriptions, unless requested
- Group related annotations together (class fields, function params, returns)

## Development & Linting

### 🚨 MANDATORY: Post-Change Validation for Lua Files

**ALWAYS run both linters after making ANY Lua file changes:**

```bash
make luals      # REQUIRED: Run type checking
make luacheck   # REQUIRED: Run style/syntax checking
```

**Not optional.** Every Lua change must pass both checks before completion.

### Type Checking

`make luals` runs Lua Language Server headless diagnosis across all files in the
project and provides comprehensive type checking.

### Available Make targets:

Make for running Lua linting and type checking tools:

- `make luals` - Run Lua Language Server headless diagnosis (type checking) -
  **Use this for full project type checks**
- `make luacheck` - Run Luacheck linter (style and syntax checking)
- `make print-vimruntime` - Display the detected VIMRUNTIME path

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

**IMPORTANT:** When adding or refactoring configuration options:

1. Add/update the configuration in `config_default.lua` with proper LuaCATS type
   annotations
2. **ALWAYS update the README.md** "Configuration" section:
   - Include default values
   - Update the configuration table if one exists
   - Document environment variables if any

#### Theme & Highlight Groups

The `lua/agentic/theme.lua` file defines all custom highlight groups used by the
plugin.

**IMPORTANT:** When adding new highlight groups:

1. Add the highlight group name to `Theme.HL_GROUPS` constant
2. Define the default highlight in `Theme.setup()` function
3. **Update the README.md** "Customization (Ricing)" section with:
   - The new highlight group in the code example
   - A new row in the "Available Highlight Groups" table

Documentation updates ensure users can discover and customize plugin features.

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

##### Provider adapters:

Each provider has a dedicated adapter in `lua/agentic/acp/adapters/`:

- `claude_acp_adapter.lua` - Claude Code ACP adapter
- `gemini_acp_adapter.lua` - Gemini ACP adapter
- `codex_acp_adapter.lua` - Codex ACP adapter
- `opencode_acp_adapter.lua` - OpenCode ACP adapter

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

## Plugin Requirements

- Neovim v0.11.0+ (make sure settings, functions, and APIs, specially around
  `vim.*` are for this version or newer)

**IMPORTANT**: For dealing with neovim native features and APIs, refer to the
official docs. Common documentation files include:

- api.txt - Neovim Lua API
- autocmd.txt - Autocommands
- change.txt - Changing text
- channel.txt - Channels and jobs
- cmdline.txt - Command-line editing
- diagnostic.txt - Diagnostics
- diff.txt - Diff mode
- editing.txt - Editing files
- fold.txt - Folding
- indent.txt - Indentation
- insert.txt - Insert mode
- job_control.txt - Job control
- lsp.txt - LSP client
- lua.txt - Lua API
- lua-guide.txt - Lua guide
- map.txt - Key mapping
- motion.txt - Motion commands
- options.txt - Options
- pattern.txt - Patterns and search
- quickfix.txt - Quickfix and location lists
- syntax.txt - Syntax highlighting
- tabpage.txt - Tab pages
- terminal.txt - Terminal emulator
- treesitter.txt - Treesitter
- ui.txt - UI
- undo.txt - Undo and redo
- windows.txt - Windows
- various.txt - Various commands

Use GitHub raw URLs or local paths (see section below) to access these files.

### 🚨 NEVER Execute `nvim` to Read Help Manuals

**CRITICAL**: Do NOT run `nvim --headless` or any other `nvim` command to read
help documentation. Use direct file access instead.

**Documentation Lookup Strategy:**

Follow this priority order to locate Neovim documentation:

1. **If OS and Neovim version are known from context:**
   - **macOS (Homebrew assumed):** Compose path directly

     ```
     /opt/homebrew/Cellar/neovim/<version>/share/nvim/runtime/doc/<doc-name>.txt
     ```

     Example for v0.11.5:
     `/opt/homebrew/Cellar/neovim/0.11.5/share/nvim/runtime/doc/api.txt`

   - **Linux (Snap assumed):** Compose path directly

     ```
     /snap/nvim/current/usr/share/nvim/runtime/doc/<doc-name>.txt
     ```

2. **If OS or version unknown:** Run discovery commands as last resort

   Find Neovim installation:

   ```bash
   realpath $(which nvim)
   ```

   Then, use appropriate path pattern based on the result

3. **If local lookup fails:** Use GitHub raw URLs (least preferred)

   ```
   https://raw.githubusercontent.com/neovim/neovim/refs/tags/v<version>/runtime/doc/<doc-name>.txt
   ```

**Why:** Running `nvim` commands can hang, cause race conditions, or interfere
with development environment.

**Tip:** Use grep on doc folder when unsure which file contains needed info.