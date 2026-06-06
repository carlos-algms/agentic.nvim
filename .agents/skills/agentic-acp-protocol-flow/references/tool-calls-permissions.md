# Tool Calls and Permission Flow

## Session update routing

| `sessionUpdate` value   | Routed to                                 |
| ----------------------- | ----------------------------------------- |
| `"tool_call"`           | `__handle_tool_call` -> subscriber        |
| `"tool_call_update"`    | `__handle_tool_call_update` -> subscriber |
| `"agent_message_chunk"` | `MessageWriter:write_message_chunk()`     |
| `"agent_thought_chunk"` | `MessageWriter:write_message_chunk()`     |
| `"plan"`                | `TodoList.render()`                       |
| `"request_permission"`  | `PermissionManager`                       |
| others                  | `subscriber.on_session_update()`          |

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
