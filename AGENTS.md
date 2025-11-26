# Agents Guide

agentic.nvim is a Neovim plugin that emulates Cursor AI IDE behavior, providing
AI-driven code assistance through a chat sidebar for interactive conversations.

## 🚨 CRITICAL: Multi-Tabpage Architecture

**EVERY FEATURE MUST BE MULTI-TAB SAFE** - This plugin supports **one instance
per tabpage**.

### Architecture Overview

- **Tabpage instance control:** `lua/agentic/init.lua` maintains
  `chat_widgets_by_tab` table
- **1 ACP provider instance** (single subprocess per provider) shared across all
  tabpages
- **1 ACP session ID per tabpage** - The ACP protocol supports multiple sessions
  per instance
- **1 SessionManager + 1 ChatWidget per tabpage** - Full UI isolation between
  tabpages

- Each tabpage has independent:
  - ACP session ID (tracked by the shared provider)
  - Chat widget (buffers, windows, state)
  - Status animation
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
   - In instance methods with `self.tabpage`: `self.tabpage`
   - From buffer: `vim.api.nvim_win_get_tabpage(vim.fn.bufwinid(bufnr))`
   - Current tabpage: `vim.api.nvim_get_current_tabpage()`

5. **ACP sessions are per-tabpage**
   - Each tabpage gets its own session ID from the shared ACP provider
   - Session state tracked independently per tabpage
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

Before submitting changes, verify isolation:

```vim
:tabnew          " Create second tabpage
:AgenticChat     " Start chat in tab 2
:tabprev         " Go back to tab 1
:AgenticChat     " Start chat in tab 1
" Both chats must work independently - no cross-contamination
" Verify: animations, highlights, sessions, namespaces all isolated
```

### Class Design Guidelines

When creating or modifying classes:

1. **Minimize class properties** - Only include properties that:
   - Are accessed by external code (other modules/classes)
   - Are part of the public API
   - Need to be accessed by subclasses or mixins

2. **Prefer private fields over unnecessary public properties** - Mark internal
   state with `_` prefix and `@private` annotation. Only expose what external
   code needs to access.

   ```lua
   -- ❌ Bad: Unnecessary public property
   --- @class MyClass
   --- @field counter number  -- Exposed to external code unnecessarily
   local MyClass = {}
   MyClass.__index = MyClass

   function MyClass:new()
       return setmetatable({ counter = 0 }, self)
   end

   function MyClass:increment()
       self.counter = self.counter + 1
   end

   -- ✅ Good: Private internal state
   --- @class MyClass
   --- @field _counter number  -- Internal implementation detail
   --- @private
   local MyClass = {}
   MyClass.__index = MyClass

   function MyClass:new()
       return setmetatable({ _counter = 0 }, self)
   end

   function MyClass:increment()
       self._counter = self._counter + 1
   end

   function MyClass:get_count()
       return self._counter  -- Controlled access if needed
   end
   ```

3. **Document intent with LuaCATS** - Use `@private` or `@package` annotations
   for fields that are implementation details:

   ```lua
   --- @class MyClass
   --- @field public_field string Public API field
   --- @field _private_field number Private implementation detail
   ```

   **Note:** Lua Language Server is configured to treat `_*` prefixed properties
   as private and will not show them in autocomplete for external consumers.

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

**When adding new public methods:**

When adding new public methods to Logger or any other commonly used utility
module, **ALWAYS update this AGENTS.md documentation** with:

1. Method signature and brief description
2. What the method does
3. Usage examples
4. Any important notes or gotchas

This prevents confusion and ensures agents know what methods are available.

## Code Style

### Lua Class Pattern

Use this standard pattern for creating Lua classes:

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

**Example with inheritance:**

```lua
-- Dog class extends Animal
--- @class Dog : Animal
local Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog

function Dog:new()
    local instance = setmetatable({}, self)
    return instance
end

function Dog:move()
    Animal.move(self)  -- Call parent method
    print("Dog runs on four legs")
end

function Dog:bark()
    print("Woof!")
end

-- Usage
local dog = Dog:new()
dog:move()
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
- **IMPORTANT:** Optional types MUST use explicit union syntax `type|nil`, NOT the `?` suffix
  - ❌ Wrong: `@param winid? number` or `@field _state? string`
  - ✅ Correct: `@param winid number|nil` or `@field _state string|nil`
  - Reason: Lua Language Server may not properly validate the `?` suffix syntax in all contexts
- Do NOT Provide meaningful parameter and return descriptions, unless requested
- Group related annotations together (class fields, function params, returns)

## Development & Linting

### Type Checking

**Always use `make luals` for full project type checks.** This runs Lua Language
Server headless diagnosis across all files in the project and provides
comprehensive type checking.

```bash
make luals  # Run full project type checking
```

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

#### Theme & Highlight Groups

The `lua/agentic/theme.lua` file defines all custom highlight groups used by the
plugin.

**IMPORTANT:** When adding new highlight groups:

1. Add the highlight group name to `Theme.HL_GROUPS` constant
2. Define the default highlight in `Theme.setup()` function
3. **Update the README.md** "Customization (Ricing)" section with:
   - The new highlight group in the code example
   - A new row in the "Available Highlight Groups" table

These documentation updates ensure users can discover and customize all aspects
of the plugin.

### Provider System

#### ACP Providers (Agent Client Protocol)

These providers spawn **external CLI tools** as subprocesses and communicate via
the Agent Client Protocol:

- **Requirements**: External CLI tools must be installed
  - `brew install gemini-cli`
  - `npm -g install @zed-industries/claude-code-acp`
  - etc...

##### ACP provider configuration:

```lua
acp_providers = {
  ["gemini-cli"] = {
    command = "gemini",                    -- CLI command to spawn
    args = { "--experimental-acp" },       -- CLI arguments
    env = { GEMINI_API_KEY = "..." },      -- Environment variables
  },
  ["claude-code"] = {
    command = "npx",
    args = { "@zed-industries/claude-code-acp" },
    env = { ANTHROPIC_API_KEY = "..." },
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
help documentation. Use these alternatives instead:

**Step 1: Find where nvim is installed**

```bash
realpath $(which nvim)
```

**Step 2: Locate docs based on installation method**

- **If under Homebrew (macOS):** Path contains `/homebrew/` or `/Cellar/`

  ```
  <homebrew-path>/Cellar/neovim/<version>/share/nvim/runtime/doc/
  ```

- **If under Snap (Linux):** Path contains `/snap/`

  ```
  /snap/nvim/current/usr/share/nvim/runtime/doc/
  ```

- **Otherwise:** Use GitHub raw URLs as fallback only (NOT PREFERRED)
  ```
  https://raw.githubusercontent.com/neovim/neovim/refs/tags/v0.11.5/runtime/doc/<doc-name>.txt
  ```

**Why:** Running `nvim` commands can hang, cause race conditions, or interfere
with the development environment. Always use static documentation sources.

ALSO, You can grep in the entire folder instead of file by file, when unsure of
the exact file to look into.
