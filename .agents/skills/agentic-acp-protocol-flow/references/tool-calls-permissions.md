# Tool Calls and Permission Flow

## Session update routing

Routing is two-layered. `ACPClient:__handle_session_update` (acp_client.lua)
handles only tool-call updates directly; every other value is forwarded verbatim
to `subscriber.on_session_update(update)`. `SessionManager:_on_session_update`
(session_manager.lua) is that subscriber and dispatches by `sessionUpdate` value
to the UI.

Layer 1 - `ACPClient:__handle_session_update`:

| `sessionUpdate` value | Routed to                                            |
| --------------------- | ---------------------------------------------------- |
| `"tool_call"`         | `__handle_tool_call` -> `on_tool_call`               |
| `"tool_call_update"`  | `__handle_tool_call_update` -> `on_tool_call_update` |
| any other value       | `subscriber.on_session_update(update)`               |

Layer 2 - `SessionManager:_on_session_update`:

| `sessionUpdate` value   | Routed to                                |
| ----------------------- | ---------------------------------------- |
| `"agent_message_chunk"` | `MessageWriter:write_message_chunk()`    |
| `"agent_thought_chunk"` | `MessageWriter:write_message_chunk()`    |
| `"user_message_chunk"`  | `MessageWriter`                          |
| `"plan"`                | `TodoList:render(update.entries)`        |
| other update types      | handled per type (commands, modes, etc.) |

`request_permission` is NOT a `sessionUpdate` value. It is the JSON-RPC method
`session/request_permission`, handled separately by
`ACPClient:__handle_request_permission` -> `subscriber.on_request_permission`.

## Tool-call lifecycle

Phase 1: initial `tool_call`

- `ACPClient.__build_tool_call_message` builds a `ToolCallBlock`.
- Subscriber receives `on_tool_call(block)`.
- `MessageWriter:write_tool_call_block(block)` renders header, body/diff,
  extmark anchor, status, and tracker state.

Phase 2: `tool_call_update`

- Updates are partial; only changed fields are sent.
- `MessageWriter:update_tool_call_block(partial)` merges onto the tracker with
  `tbl_deep_extend`.
- Body chunks with changed text are appended with separators.
- Block position comes from range extmarks.
- If a diff already rendered, only header and status refresh.

Phase 3: terminal update

- Status becomes `completed` or `failed`.
- Failed status removes pending permission requests.

## Design rules

- Updates are partial.
- Diffs are immutable after first render.
- Body accumulates across changed body updates.
- Range extmark in `NS_TOOL_BLOCKS` is the block position source of truth.

## Permission flow

- `session/request_permission` is normalized into a tool-call update.
- Missing tracker requests route through first render.
- Missing fields default to `other(Pending)` and `pending`.
- `PermissionManager:add_request` stores pending requests by `tool_call_id` and
  preserves insertion order.
- Focus tracks the oldest pending request; new arrivals do not steal focus.
- Digit keys dispatch the focused block option.
- Cycle keys switch pending-block focus.
- Resolving a permission clears the diff preview and advances to the next
  pending request.

Regression:

- `lua/agentic/ui/message_writer.test.lua::"defaults missing initial tool call fields before render"`
