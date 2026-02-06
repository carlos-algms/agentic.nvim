# Design: Session Persistence

## Context

Agentic.nvim currently keeps all conversation history in memory only. When
users close Neovim or start a new session, all context is lost. This design
adds session persistence inspired by OpenCode's approach but adapted for
Neovim's architecture and focused on session restoration rather than
provider/model switching.

**Key differences from OpenCode:**

- OpenCode: Writes on every streaming chunk for crash recovery
- Agentic.nvim: Writes only on turn completion (simpler, less I/O)
- OpenCode: TypeScript with AI SDK message format
- Agentic.nvim: Lua with ACP protocol message format
- OpenCode: Sends history to new model on switch
- Agentic.nvim: Restores UI only (foundation for future model switching)

## Goals / Non-Goals

**Goals:**

- Persist conversation history across Neovim restarts
- Allow users to restore previous sessions via explicit API call
- Store session metadata (ID, title from first message)
- Minimal performance impact (write only on turn completion)
- Simple, maintainable implementation
- Foundation for future provider/model switching

**Non-Goals:**

- Provider/model switching (deferred to future work)
- Real-time crash recovery (incomplete turns not saved)
- Automatic session list/picker UI (users call API directly)
- Multi-device sync
- Encryption/compression
- Cross-tabpage session sharing

## Decisions

### Storage Format: JSON

**Decision:** Store messages as JSON array in plain text files.

**Why:**

- Human-readable for debugging
- Native Lua `vim.json` support
- Simple versioning (add `version` field if schema changes)
- Easy migration path if needed

**Alternatives considered:**

- MessagePack: Faster but not human-readable, requires dependency
- Lua serialization: Not portable, hard to version

### Storage Location: Flat Folder Structure

**Decision:** Store sessions in `~/.cache/nvim/agentic/sessions/<normalized_path_hash>/<session_id>.json`

**Why:**

- Standard Neovim convention via `vim.fn.stdpath("cache")`
- Project isolation via normalized path + hash
- Flat structure (no nested folders)
- Readable folder names showing project path
- Multiple sessions per project (one JSON file per session)

**Path generation (inside ChatHistory class):**

```lua
-- Example CWD: /Users/me/projects/myapp
-- Normalized: Users_me_projects_myapp
-- Hash: 123456
-- Folder: Users_me_projects_myapp_123456
-- Session: abc123
-- Result: ~/.cache/nvim/agentic/sessions/Users_me_projects_myapp_123456/abc123.json

ChatHistory:new(session_id) -- uses CWD
ChatHistory:new(session_id, "/custom/base") -- custom base

-- Implementation:
function ChatHistory:_get_project_folder()
    local cwd = vim.uv.cwd() or ""

    -- Normalize: replace slashes, spaces, and colons with underscores
    local normalized = cwd:gsub("[/\\%s:]", "_")

    -- Strong hash for collision resistance (first 8 chars of SHA256)
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

function ChatHistory:_get_file_path()
    local base = self.dir_path or vim.fn.stdpath("cache")
    local project_folder = self:_get_project_folder()
    local folder = vim.fs.joinpath(base, "agentic", "sessions", project_folder)
    return vim.fs.joinpath(folder, self.session_id .. ".json")
end
```

### Message Storage: ACP Protocol Format

**Decision:** Store messages as-is from ACP protocol (`SessionUpdateMessage`
types).

**Why:**

- No format conversion needed
- Preserves provider-specific metadata
- Matches in-memory representation
- Simple to serialize/deserialize

**What gets stored:**

- `user_message_chunk` - User prompts with full content
- `agent_message_chunk` - Agent text responses
- `agent_thought_chunk` - Reasoning/thinking blocks
- `tool_call` - Tool invocations with final state (updates merge into original)

**What doesn't get stored:**

- UI state (scroll position, window layout)
- Extmarks/decorations
- Permission requests (transient)
- Status animations (transient)

### Async Save Strategy

**Decision:** Save to disk asynchronously using `vim.uv.fs_*` APIs after turn
completion.

**Why:**

- Non-blocking I/O prevents UI freezes during large saves
- Single async write per turn (minimal overhead)
- Natural integration point in existing code
- Errors logged but don't block user workflow

**Implementation using `vim.uv.fs_*`:**

```lua
-- ChatHistory:save(callback)
function ChatHistory:save(callback)
    local path = self:_get_file_path()
    local dir = vim.fn.fnamemodify(path, ":h")

    -- Step 1: Create directory (synchronous, recursive)
    vim.fn.mkdir(dir, "p")

    -- Step 2: Serialize JSON with pcall for safety
    local data = {
        session_id = self.session_id,
        title = self:get_title(),
        timestamp = self.timestamp,
        messages = self.messages
    }
    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        Logger.debug("JSON encoding failed:", json)
        if callback then callback("JSON encoding error") end
        return
    end

        -- Step 3: Write file async
        vim.uv.fs_open(path, "w", 420, function(err_open, fd) -- 420 = 0644
            if err_open then
                Logger.debug("Failed to open:", err_open)
                if callback then callback(err_open) end
                return
            end

            vim.uv.fs_write(fd, json, 0, function(err_write)
                vim.uv.fs_close(fd)
                if err_write then
                    Logger.debug("Failed to write:", err_write)
                end
                if callback then callback(err_write) end
            end)
        end)
    end)
end

-- session_manager.lua:341
self.agent:send_prompt(self.session_id, prompt, function(response, err)
    vim.schedule(function()
        -- ... existing finish message logic ...

        -- NEW: Async save (non-blocking)
        if not err then
            self.chat_history:save(function(save_err)
                if save_err then
                    Logger.debug("Save error:", save_err)
                end
            end)
        end
    end)
end)
```

### Message Replay Strategy

**Decision:** Replay all message types to UI via MessageWriter, then send history to agent on first user submit.

**Why:**

- Users want to see complete conversation including tool calls (UI replay)
- Different message types need different rendering (text, chunks, tool blocks)
- Agent needs history context when user continues conversation (send on first submit)
- Reuses existing MessageWriter code for rendering

**Implementation:**

```lua
-- In SessionManager:_replay_messages(messages)
function SessionManager:_replay_messages(messages)
    for _, msg in ipairs(messages) do
        if msg.sessionUpdate == "user_message_chunk" or
           msg.sessionUpdate == "agent_message_chunk" then
            -- Write complete messages
            self.message_writer:write_message(msg)
        elseif msg.sessionUpdate == "agent_thought_chunk" then
            -- Write thought chunks
            self.message_writer:write_message_chunk(msg)
        elseif msg.sessionUpdate == "tool_call" then
            -- Write tool call blocks with final state
            self.message_writer:write_tool_call_block(msg)
        end
        -- Note: tool_call_update not stored separately, merged into tool_call
    end
end

-- In SessionManager:restore_from_history(chat_history)
function SessionManager:restore_from_history(chat_history)
    self.chat_history = chat_history
    self:_replay_messages(chat_history:get_messages())
    -- Mark that we need to send history on first submit
    self._needs_history_send = true
end

-- In SessionManager:_handle_input_submit(input_text)
function SessionManager:_handle_input_submit(input_text)
    local prompt = {}

    -- If restored session, prepend history on first submit
    if self._needs_history_send then
        self._needs_history_send = false
        -- Convert stored messages to Content[] format
        for _, msg in ipairs(self.chat_history:get_messages()) do
            if msg.content then
                table.insert(prompt, msg.content)
            end
        end
    end

    -- Add system info if first message...
    -- Add current user prompt (ensure it's last)
    table.insert(prompt, { type = "text", text = input_text })

    self.agent:send_prompt(self.session_id, prompt, callback)
end
```

### File Format: Session Metadata + Messages

**Decision:** Store session_id, title (first user message), and messages array.

**Why:**

- Session ID enables deterministic file paths and restoration
- Title provides human-readable context (for future session picker UI)
- Messages array preserves full conversation

**JSON structure:**

```json
{
    "session_id": "abc123",
    "title": "First user message text...",
    "timestamp": 1704067200,  -- Unix timestamp (os.time() when session created)
    "messages": [
        { "sessionUpdate": "user_message_chunk", "content": {...} },
        { "sessionUpdate": "agent_message_chunk", "content": {...} },
        ...
    ]
}
```

**Title extraction:** First `user_message_chunk` with `content.type == "text"`,
truncated to 100 characters.

**Timestamp:** Captured via `os.time()` when ChatHistory is created (session
start time).

## Architecture Integration

### Class Responsibilities

**`ChatHistory`:**

- Store `session_id` (required), `timestamp` (session start time via
  `os.time()`), and optional `dir_path`
- Hold messages in memory (`self.messages = {}`)
- Generate project folder via `_get_project_folder()` (normalize CWD + hash)
- Generate file path via `_get_file_path()` (returns
  `<cache>/sessions/<normalized_path_hash>/<session_id>.json`)
- Add new messages (`add_message()`)
- Extract title from first user message (`get_title()`)
- Async save to disk (`save(callback)` - writes session_id, title, timestamp,
  messages)
- Async load from disk (`load(session_id, dir_path, callback)` - static method,
  restores timestamp)
- Clear history (`clear()`)

**`SessionManager`:**

- Create `ChatHistory` instance after ACP session created
- Trigger `chat_history:save(callback)` async after turn completion
- Clear history in `_cancel_session()`
- Replay messages to UI (`_replay_messages(messages)` - handles all message
  types)
- Restore from history (`restore_from_history(chat_history)` - calls
  `_replay_messages`)

**`init.lua` (extended):**

- Add `restore_session(session_id, opts)` public method
- Async load ChatHistory via `ChatHistory.load(session_id, nil, callback)`
- In callback, create SessionManager and call `restore_from_history()`

### Data Flow

```
User Input
    ↓
SessionManager:_handle_input_submit()
    ↓
ChatHistory:add_message(user_message) -- in memory
    ↓
ACPClient:send_prompt()
    ↓
... streaming response ...
    ↓
Prompt callback (on completion)
    ↓
ChatHistory:add_message(agent_message) -- in memory
    ↓
ChatHistory:save(callback) -- async write JSON via vim.uv.fs_*
    ↓
(background) fs_mkdir -> fs_open -> fs_write -> fs_close
    ↓
callback(err) -- log errors, don't block UI
```

### File Structure

```jsonc
// Stored JSON format
{
    "session_id": "abc123",
    "title": "Fix the authentication bug in login.lua",
    "messages": [
        {
            "sessionUpdate": "user_message_chunk",
            "content": { "type": "text", "text": "Fix the authentication bug in login.lua" }
        },
        {
            "sessionUpdate": "agent_message_chunk",
            "content": { "type": "text", "text": "I'll help you fix that..." }
        },
        ...
    ]
}
```

**Title extraction:** First `user_message_chunk` with `content.type == "text"`,
truncated to 100 characters.

## Risks / Trade-offs

### Risk: Stale/Corrupted Files

**Mitigation:**

- Gracefully handle JSON decode errors (log warning, return nil)
- Store session_id for validation
- Future: Add version field if schema changes

### Risk: Large History Files

**Trade-off:**

- Accepted: No automatic pruning/compression
- Users can manually delete `~/.cache/nvim/agentic/sessions/` if needed
- Typical sessions <1MB (100s of turns)

**Future:** Could add max message limit or auto-archival if needed.

### Risk: I/O Performance

**Mitigation:**

- Async writes via `vim.uv.fs_*` prevent UI freezes
- Single async write per turn (not per chunk)
- Errors logged but don't block user workflow
- `vim.schedule()` already used for turn completion callback

## Migration Plan

**Phase 1: Add Persistence (This Change)**

- New `ChatHistory` class with session_id-based filenames
- SessionManager integration for save/restore
- Public `restore_session()` API in init.lua
- No breaking changes (feature is additive)

**Phase 2: Session Picker UI (Future)**

- List all session files in cache directory
- Display titles for user selection
- Call `restore_session()` on selection

**Phase 3: Provider/Model Switching (Future)**

- Extend restoration to send history to agent (not just UI)
- Store provider name in history metadata
- Modify SessionManager to handle provider transitions

**Rollback:**

- Remove `chat_history` field from SessionManager
- Remove `restore_session()` from init.lua
- Delete `ChatHistory` module
- No schema migration needed (files just ignored)

## Open Questions

- Should we auto-save on every turn or only on explicit save? (Decision: every
  turn)
- Should we expose a command to list sessions? (Defer to Phase 2)
- Should we limit maximum history size? (Lean toward: no, defer until proven
  needed)
