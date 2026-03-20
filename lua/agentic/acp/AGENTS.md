# Provider system

## ACP providers (Agent Client Protocol)

This plugin spawns **external CLI tools** as subprocesses and communicates via
the Agent Client Protocol:

- **Requirements**: External CLI tools must be installed by the user, we don't
  install them for security reasons.
  - `claude-agent-acp` for Claude
  - `gemini` for Gemini
  - `codex-acp` for Codex
  - `opencode` for OpenCode
  - `cursor-agent-acp` for Cursor Agent
  - `auggie` for Augment Code
  - `vibe-acp` for Mistral Vibe

NOTE: Install instructions are in the README.md

## Generic ACPClient (no per-provider adapters)

All providers use a **single generic `ACPClient`** (`acp_client.lua`). There are
no per-provider adapter files.

The client parses standard ACP protocol fields and handles provider quirks (e.g.
`rawInput` fallback for OpenCode) inline via protected methods in `ACPClient`
itself.

**Adding a new provider** only requires a config entry in `config_default.lua`
under `acp_providers` — no adapter code needed unless the provider deviates from
ACP in ways not yet handled.

## ACP provider configuration

```lua
acp_providers = {
  ["claude-agent-acp"] = {
    name = "Claude Agent ACP",
    command = "claude-agent-acp",
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
  ["gemini-acp"] = {
    name = "Gemini ACP",
    command = "gemini",
    args = { "--acp" },
    env = {
      NODE_NO_WARNINGS = "1",
      IS_AI_TERMINAL = "1",
    },
  },
}
```

## Event pipeline (top to bottom)

```
Provider subprocess (external CLI)
  | stdio: newline-delimited JSON-RPC
  v
ACPTransport      -- parses JSON, calls callbacks.on_message()
  |
  v
ACPClient         -- routes by message type (notification vs response)
  |  protected methods: __handle_tool_call,
  |  __handle_tool_call_update, __build_tool_call_message
  v
SessionManager    -- registered as subscriber per session_id
  |  routes by sessionUpdate type
  |  (see "Session update routing" below)
  v
MessageWriter     -- writes to chat buffer, tracks tool call state
PermissionManager -- queues permission prompts, manages keymaps
ChatHistory       -- accumulates messages for persistence
```

## Session update routing

`ACPClient` receives `session/update` notifications. The `sessionUpdate` field
determines routing:

| `sessionUpdate` value   | Routed to                                  |
| ----------------------- | ------------------------------------------ |
| `"tool_call"`           | `__handle_tool_call` → subscriber          |
| `"tool_call_update"`    | `__handle_tool_call_update` → subscriber   |
| `"agent_message_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"agent_thought_chunk"` | `MessageWriter:write_message_chunk()`      |
| `"plan"`                | `TodoList.render()`                        |
| `"request_permission"`  | `PermissionManager` (queued, sequential)   |
| others                  | `subscriber.on_session_update()` (generic) |

## Tool call lifecycle

Tool calls go through **3 phases**. `MessageWriter` tracks each via
`tool_call_blocks[tool_call_id]`, persisting state across all phases.

**Phase 1 — `tool_call` (initial)**

```
Provider sends "tool_call"
  -> ACPClient builds ToolCallBlock via __build_tool_call_message
     { tool_call_id, kind, argument, status, body?, diff? }
  -> subscriber.on_tool_call(block)
  -> MessageWriter:write_tool_call_block(block)
     1. Renders header + body/diff lines to buffer
     2. Creates range extmark (NS_TOOL_BLOCKS) as position anchor
     3. Creates decoration extmarks (borders, status icon)
     4. Stores block in tool_call_blocks[id]
```

**Phase 2 — `tool_call_update` (one or more)**

```
Provider sends "tool_call_update"
  -> ACPClient builds ToolCallBase via __build_tool_call_message
     (only CHANGED fields needed — MessageWriter merges)
  -> subscriber.on_tool_call_update(partial)
  -> MessageWriter:update_tool_call_block(partial)
     1. Looks up tracker = tool_call_blocks[id]
     2. Deep-merges via tbl_deep_extend("force", tracker, partial)
     3. Appends body (if both old and new exist and differ)
     4. Locates block position via range extmark
     5. Diff already rendered: refresh decorations + status only
        (content frozen to prevent flicker)
     6. Diff is NEW: replace buffer lines, re-render everything
```

**Phase 3 — final `tool_call_update` with terminal status**

```
Same as Phase 2, but status = "completed" | "failed"
  -> Visual status icon updates to final state
  -> If "failed": PermissionManager removes pending request
```

## Key design rules

- **Updates are partial:** Only send what changed. MessageWriter merges onto the
  existing tracker via `tbl_deep_extend`.
- **Diffs are immutable after first render:** Once a diff is written to the
  buffer, content is frozen. Only status/decorations refresh on subsequent
  updates.
- **Body accumulates:** Multiple updates with different body content get
  concatenated with `---` dividers, not replaced.
- **Extmarks as position anchors:** Range extmark in `NS_TOOL_BLOCKS`
  auto-adjusts when buffer content shifts. Single source of truth for block
  position.

## Provider quirk handling

Instead of per-provider adapters, `ACPClient` handles protocol deviations inline
in `__build_tool_call_message`:

- **`rawInput` fallback** (OpenCode): when `content` is missing for `edit` kind
  tool calls, builds diff from `rawInput.new_string`/`rawInput.newString` fields
- **`locations` fallback**: extracts `file_path` from `update.locations[0].path`
  when not in `rawInput`
- **Unknown kinds**: logs a warning for unrecognized `kind` values so users
  report them as issues

To handle a new provider quirk, add the fallback logic in
`__build_tool_call_message` with a comment explaining which provider needs it.

## Permission flow (interleaved with tool calls)

```
Provider sends "session/request_permission"
  -> SessionManager: opens diff preview (if the request carries a diff)
  -> PermissionManager:add_request(request, callback)
     -> Queues request (sequential — one prompt at a time)
     -> Renders permission buttons in chat buffer
     -> Sets up buffer-local keymaps (1,2,3,4)
  -> User presses key
     -> Sends result back to provider via callback
     -> Clears diff preview
     -> Dequeues next permission if any
```

## Protected methods in ACPClient

These protected methods can be overridden by subclasses if a future provider
requires it, but currently all providers use the default implementations:

| Method                        | Behavior                                  |
| ----------------------------- | ----------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock, notifies subscriber |
| `__build_tool_call_message`   | Parses ACP fields + quirk fallbacks       |
| `__handle_tool_call_update`   | Builds partial, notifies subscriber       |
| `__handle_request_permission` | Sends result back to provider             |
| `__handle_session_update`     | Routes by `sessionUpdate` type            |
