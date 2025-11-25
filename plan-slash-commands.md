# Implementation Plan: Slash Commands from ACP Agent

## Overview

Implement support for slash commands provided by ACP agents during
initialization. The ACP protocol sends available commands through the
`available_commands_update` session update message, which needs to be captured,
stored, and made accessible to the session manager.

## Current State Analysis

### Real Data from Codex ACP Provider

**Example `session/update` message with commands:**

```lua
{
  jsonrpc = "2.0",
  method = "session/update",
  params = {
    sessionId = "019abcb0-741f-7e72-b38c-ce56cd840988",
    update = {
      availableCommands = {
        {
          description = "Review my current changes and find issues",
          input = { hint = "optional custom review instructions" },
          name = "review"
        },
        {
          description = "Review the code changes against a specific branch",
          input = { hint = "branch name" },
          name = "review-branch"
        },
        {
          description = "Review the code changes introduced by a commit",
          input = { hint = "commit sha" },
          name = "review-commit"
        },
        {
          description = "create an AGENTS.md file with instructions for Codex",
          input = nil,
          name = "init"
        },
        {
          description = "summarize conversation to prevent hitting the context limit",
          input = nil,
          name = "compact"
        },
        {
          description = "logout of Codex",
          input = nil,
          name = "logout"
        }
      },
      sessionUpdate = "available_commands_update"
    }
  }
}
```

**Key Observations:**

- Commands arrive as `session/update` notification after session creation
- Command `name` field does **NOT** include `/` prefix (e.g., "review" not
  "/review")
- `input` field can be:
  - A table with `hint` field (for commands with parameters)
  - `nil` (for commands without parameters - shown as `vim.NIL` in vim.inspect
    output)
- Codex provides 6 commands in this example
- Commands are sent immediately after session initialization

### Existing Infrastructure

1. **Type Definitions** (lua/agentic/acp/acp_client.lua:789-795)
   - `agentic.acp.AvailableCommand` type exists with fields:
     - `name: string` - Command name **without** `/` prefix (e.g., "review")
     - `description: string` - Command description
     - `input?: table<string, any>` - Optional input schema (nil for commands
       without parameters)
   - `agentic.acp.AvailableCommandsUpdate` type exists:
     - `sessionUpdate: "available_commands_update"`
     - `availableCommands: agentic.acp.AvailableCommand[]`

2. **Message Flow** (lua/agentic/session_manager.lua:99-101)
   - `SessionManager:_on_session_update()` already receives the update
   - Currently logs "Implement available_commands_update handling"
   - No storage or processing implemented

3. **Architecture Context**
   - **One ACP provider instance** shared across all tabpages
   - **One session ID per tabpage** - each tabpage has independent session
   - Available commands are **per-session** (sent during session initialization)
   - SessionManager is **per-tabpage** and manages its own session

### ACP Protocol Flow

According to the
[ACP Slash Commands docs](https://agentclientprotocol.com/protocol/slash-commands.md):

1. After `session/new` or `session/load`, agent sends `session/update`
   notification
2. The update includes `available_commands_update` with list of commands
3. Commands are session-specific (different sessions may have different
   commands)

## Implementation Plan

### 1. Create Slash Commands Module

**File:** `lua/agentic/acp/slash_commands.lua`

**Purpose:** Simple storage for slash commands (per-tabpage, managed by
SessionManager)

**Class Design:**

```lua
--- Simplified command structure (only what we need)
--- @class agentic.acp.SlashCommand
--- @field name string Command name without `/` prefix
--- @field description string Command description

--- @class agentic.acp.SlashCommands
--- @field list agentic.acp.SlashCommand[] Public list of commands
local SlashCommands = {}
SlashCommands.__index = SlashCommands

function SlashCommands:new()
    local instance = setmetatable({ list = {} }, self)
    return instance
end

--- Replace all commands with new list (keeps only name and description)
--- @param commands agentic.acp.AvailableCommand[]
function SlashCommands:setCommands(commands)
    self.list = {}
    for _, cmd in ipairs(commands) do
        if cmd.name and cmd.description then
            table.insert(self.list, {
                name = cmd.name,
                description = cmd.description,
            })
        end
    end
end
```

**Key Design Decisions:**

- **Per-tabpage instance**: Each SessionManager creates its own SlashCommands
  instance
- **No session_id tracking**: SessionManager handles session lifecycle, not this
  class
- **Minimal API**: Only `setCommands()` method and `list` property
- **Strip unnecessary fields**: Store only `name` and `description`, discard
  `input` field
- **Public `list` property**: Direct access to command list for consumers

**Implementation Notes:**

- SessionManager creates one SlashCommands instance per tabpage
- `setCommands()` clears existing commands and stores new ones
- Extract only `name` and `description` from incoming commands
- No getter method needed - consumers access `instance.list` directly
- **NO validation needed for `/` prefix** - commands come without it (e.g.,
  "review" not "/review")
- Add `/` prefix only when displaying/using commands in UI
- `input` field is discarded (not stored)

### 2. Integrate with SessionManager

**File:** `lua/agentic/session_manager.lua`

**Changes Required:**

#### 2.1 Add SlashCommands Reference

```lua
--- @class agentic.SessionManager
--- @field slash_commands agentic.acp.SlashCommands
```

#### 2.2 Initialize in Constructor

```lua
function SessionManager:new(tab_page_id)
    local SlashCommands = require("agentic.acp.slash_commands")
    -- ... existing code ...
    instance.slash_commands = SlashCommands:new()
    -- ... existing code ...
end
```

#### 2.3 Handle available_commands_update (line 99-101)

Replace the FIXIT comment with:

```lua
elseif update.sessionUpdate == "available_commands_update" then
    self.slash_commands:setCommands(update.availableCommands)
    Logger.debug(
        string.format(
            "Updated %d slash commands for session %s",
            #self.slash_commands.list,
            self.session_id or "unknown"
        )
    )
```

#### 2.4 Cleanup on Session End

In `SessionManager:_cancel_session()` (after line 292):

```lua
function SessionManager:_cancel_session()
    if not self.session_id then
        return
    end

    self.agent:cancel_session(self.session_id)
    self.permission_manager:clear()

    -- Clear slash commands
    self.slash_commands:setCommands({})
end
```

### 3. Error Handling

**Scenarios to Handle:**

1. **Empty command list**
   - Store empty array (valid state)
   - Some agents may not provide commands

2. **Invalid command format**
   - Validate each command has required fields (name, description)
   - Log warning, skip invalid commands
   - Continue processing valid commands

3. **Missing fields**
   - Skip commands without `name` or `description`
   - Log warning for malformed commands
   - `input` field is ignored (not stored)

4. **Session ends before commands received**
   - Safe to ignore (commands won't be used)
   - Cleanup will handle any partial state

## Implementation Order

1. ✅ **Step 1:** Create `lua/agentic/acp/slash_commands.lua` module
   - Implement SlashCommands class with `setCommands()` and `list` property
   - Add comprehensive LuaCATS annotations
   - Include validation for name/description fields

2. ✅ **Step 2:** Integrate with SessionManager
   - Add slash_commands field to SessionManager
   - Handle available_commands_update message
   - Add cleanup in \_cancel_session

3. ✅ **Step 3:** Testing and validation
   - Run `make luals` to verify type safety
   - Test with real ACP provider
   - Verify multi-tabpage isolation

## Technical Considerations

### Multi-Tabpage Safety

**Verified Safe Pattern:**

- Each SessionManager (per-tabpage) creates its own SlashCommands instance
- No shared state between tabpages - each instance is independent
- Commands automatically cleaned up when SessionManager is destroyed
- No memory leaks since instances are tabpage-scoped

### Memory Management

- Commands stored in per-tabpage SlashCommands instance
- Cleared when session cancelled via `setCommands({})`
- Instance destroyed with SessionManager when tabpage closes
- No manual cleanup needed - garbage collected with SessionManager

### Type Safety

- All types already defined in acp_client.lua
- New `agentic.acp.SlashCommand` type for simplified storage
- LuaCATS annotations for all public APIs
- No private fields needed - minimal class design

### Logging Strategy

- DEBUG level: Command updates, normal operations
- WARN level: Invalid commands, missing fields
- ERROR level: Critical failures (should not occur in normal operation)

## Dependencies

**Required Files:**

- lua/agentic/acp/acp_client.lua (types already exist)
- lua/agentic/session_manager.lua (modification needed)
- lua/agentic/utils/logger.lua (existing, for logging)

**No External Dependencies:**

- Pure Lua implementation
- Uses existing infrastructure
- No new external libraries needed

## Documentation Updates

After implementation, update:

1. **README.md**
   - Add section about slash commands support
   - Document how to check available commands (once UI exposed)
   - Add example commands from different providers

2. **AGENTS.md**
   - Document SlashCommands module architecture
   - Explain per-tabpage command storage
   - Note multi-tabpage safety pattern

3. **Code Comments**
   - Remove FIXIT comments in session_manager.lua
   - Add implementation references to ACP docs
   - Document any provider-specific behaviors

## Success Criteria

Implementation is complete when:

1. ✅ SlashCommands module exists with full functionality
2. ✅ SessionManager receives and stores commands per session
3. ✅ Commands are cleaned up when sessions end
4. ✅ Multi-tabpage isolation verified
5. ✅ Type checking passes (`make luals`)
6. ✅ Manual testing confirms correct behavior
7. ✅ No memory leaks or orphaned data

## References

- **ACP Slash Commands:**
  https://agentclientprotocol.com/protocol/slash-commands.md
- **ACP Session Setup:**
  https://agentclientprotocol.com/protocol/session-setup.md

