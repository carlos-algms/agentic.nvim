## Context

The ACP protocol defines two mode-switching directions:

1. **Client-initiated:** Client sends `session/set_mode` request
   (already implemented via `AgentModes` +
   `SessionManager:_handle_mode_change`)
2. **Agent-initiated:** Agent sends `session/update` notification
   with `sessionUpdate: "current_mode_update"` and `currentModeId`
   (NOT implemented)

### Two-message sequence from agent

When an agent switches modes (e.g., plan -> code), two
`session/update` messages arrive in sequence:

**Message 1 - Tool call (`switch_mode` kind):**

```lua
{
  method = "session/update",
  params = {
    sessionId = "...",
    update = {
      sessionUpdate = "tool_call",
      kind = "switch_mode",
      title = "Ready to code?",
      toolCallId = "toolu_01GJ42...",
      status = "pending",
      rawInput = { plan = "..." },
    },
  },
}
```

This already flows through the existing tool_call -> permission ->
tool_call_update pipeline via each provider's adapter. The tool call
renders in the chat. The only gap is `"switch_mode"` missing from
the `ToolKind` alias (type checker warning).

**Message 2 - Mode update notification:**

```lua
{
  method = "session/update",
  params = {
    sessionId = "...",
    update = {
      sessionUpdate = "current_mode_update",
      currentModeId = "acceptEdits",
    },
  },
}
```

This is the missing handler. Currently falls to the `else` branch
in `SessionManager:_on_session_update` and gets logged as "Unknown
session update type."

### Full flow

```text
Agent turn running (plan mode)
  1. tool_call { kind="switch_mode" }
     -> Adapter __handle_tool_call (provider-specific)
     -> MessageWriter renders tool call block in chat
  2. session/request_permission
     -> PermissionManager shows buttons
  3. User grants permission
  4. tool_call_update { status="completed" }
  5. current_mode_update { currentModeId="code" }
     -> NEW: SessionManager._on_session_update handler
     -> Update AgentModes.current_mode_id (state only)
     -> Re-render chat header
     -> Logger.notify user
     -> NO session/set_mode sent back to agent
  6. Agent continues in new mode
```

## Goals / Non-Goals

- **Goal:** Handle `current_mode_update` in `_on_session_update` -
  update internal state and re-render header
- **Goal:** Add `"switch_mode"` to `ToolKind` alias for type safety
- **Goal:** Add `CurrentModeUpdate` type to `SessionUpdateMessage`
  union
- **Non-Goal:** Changing adapter-level tool call handling (each
  adapter already handles `switch_mode` tool calls through its
  existing `__handle_tool_call` code paths)
- **Non-Goal:** Changing client-initiated mode switching
  (`_handle_mode_change` stays as-is)

## Decisions

### All handling in shared code, not adapters

`current_mode_update` is a protocol-level `sessionUpdate` type, not
provider-specific. It dispatches through `__handle_session_update` ->
subscriber `on_session_update` -> `SessionManager:_on_session_update`.
All providers benefit from a single `elseif` branch there.

Similarly, `"switch_mode"` in `ToolKind` is a protocol-level kind
value. Adding it to the alias in `acp_client.lua` covers all
providers.

### Separate handler from `_handle_mode_change`

`_handle_mode_change` sends `session/set_mode` back to the agent.
The new `current_mode_update` handler MUST NOT do this - the agent
already changed its own mode and is informing us. Sending
`set_mode` back would be redundant or cause loops.

New handler: receive notification -> update state -> re-render
header -> notify user. No round-trip to agent.

### Reuse `_set_mode_to_chat_header`

Already handles known modes (displays `mode.name`) and unknown mode
IDs (displays raw `mode_id` as fallback). Reuse directly.

## Risks / Trade-offs

- **Risk:** Provider sends `current_mode_update` with mode ID not in
  `availableModes`.
  - Mitigation: `_set_mode_to_chat_header` falls back to raw
    mode_id string.

## Open Questions

None.
