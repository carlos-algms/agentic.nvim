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
no per-provider adapter files. See ADR 0005.

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

```mermaid
flowchart TD
    Provider[Provider subprocess<br/>external CLI]
    Transport[ACPTransport<br/>parses JSON, calls<br/>callbacks.on_message]
    Client[ACPClient<br/>routes notification vs response<br/>__handle_tool_call,<br/>__handle_tool_call_update,<br/>__build_tool_call_message]
    Session[SessionManager<br/>subscriber per session_id<br/>routes by sessionUpdate type<br/>see 'Session update routing']
    Writer[MessageWriter<br/>writes to chat buffer<br/>tracks tool call state]
    Perm[PermissionManager<br/>renders inline buttons on row N<br/>concurrent pending map keyed by tool_call_id]
    History[ChatHistory<br/>accumulates messages<br/>for persistence]

    Provider -->|stdio: newline-delimited JSON-RPC| Transport
    Transport --> Client
    Client --> Session
    Session --> Writer
    Session --> Perm
    Session --> History
```

## ACPClient lifecycle (state machine)

State lives on `ACPClient.state`. The transport's `on_state_change`
callback drives `connecting -> connected -> error | disconnected`. The
RPC responses to `initialize` and `authenticate` drive the rest.

```mermaid
stateDiagram-v2
    [*] --> disconnected
    disconnected --> connecting: _connect()
    connecting --> connected: spawn ok, pipes open
    connected --> initializing: send 'initialize'
    initializing --> authenticating: auth_method set
    initializing --> ready: no auth required
    authenticating --> ready: auth response ok
    disconnected --> connecting: reconnect (if enabled)

    state "any state" as any
    any --> disconnected: process exit
    any --> error: transport error

    note right of disconnected
        on entry: _drain_pending_callbacks
        rejects all pending RPC callbacks
        with TRANSPORT_ERROR
    end note
    note right of error
        on entry: _drain_pending_callbacks
    end note
    note right of ready
        on entry: flush ready_listeners
        (each via vim.schedule)
    end note
```

Invariants:

- `_drain_pending_callbacks` runs on every transition to
  `disconnected` or `error`. It rejects every pending RPC callback
  with `TRANSPORT_ERROR`. Without it, `send_prompt`, `create_session`,
  and the rest of `_send_request`-based calls hang forever when the
  provider dies.
- Reconnect (when `provider_config.reconnect` is true) loops back to
  `connecting`. See "Reconnect" section below.
- `_on_ready` fan-out: callers registered via `when_ready` before the
  client reaches `ready` are flushed (each via `vim.schedule`) at the
  moment of transition. After `ready`, new `when_ready` callers fire
  immediately (still via `vim.schedule`), so the callback contract is
  the same in both cases.

## Stdio transport line framing

The stdio transport reads from the provider's stdout in arbitrary
chunks. JSON-RPC messages are newline-delimited, but a single chunk
may split mid-message or carry several messages plus a partial
trailer.

```text
chunk 1:  ...{"jsonrpc":"2.0","i
                              ╰── partial, no newline yet
chunk 2:  d":1,...}\n{"jsonrpc":"2.0","method
          ╰─────────╯         ╰─────────────╯
          completes prior     partial again
```

The buffering loop in `acp_transport.create_stdio_transport`:

```text
chunks = chunks .. data
lines  = split(chunks, "\n")
chunks = lines[#lines]    -- keep partial trailer for next read
for i = 1, #lines - 1 do
    dispatch(decode(trim(lines[i])))
end
```

Invariants:

- `chunks` always holds the unterminated tail across reads.
- A single read can dispatch zero or more complete messages.
- Empty/whitespace-only lines are skipped, not dispatched.
- JSON-decode failures `Logger.notify` and continue; they do not
  corrupt the buffer.

Why preserved: large payloads (tool-call diffs, big agent message
chunks) routinely exceed a single pipe-read. Dropping the
partial-tail buffer turns every multi-chunk message into a JSON parse
error that surfaces as silent message loss.

## Sync vs async dispatch

`ACPClient:_handle_message` runs inside the libuv stdout callback,
i.e. in fast event context. The two dispatch branches differ in where
the user-supplied callback ultimately runs:

```mermaid
flowchart TD
    Entry["_handle_message<br/>(fast context)"]
    Branch{has id + result/error?}
    RPC["RPC response<br/>self.callbacks[id](...)<br/><b>SYNC, fast context</b>"]
    Notif["notification<br/>_handle_notification"]
    Update["__handle_session_update"]
    Sub["__with_subscriber"]
    Sched["vim.schedule(cb)<br/><b>ASYNC, main loop</b>"]

    Entry --> Branch
    Branch -->|yes| RPC
    Branch -->|no, has method| Notif
    Notif --> Update
    Update --> Sub
    Sub --> Sched
```

Implications for callers:

- RPC callbacks passed to `_send_request` (used by `create_session`,
  `send_prompt`, `set_mode`, `set_model`, `set_config_option`,
  `load_session`, `list_sessions`, `authenticate`, `initialize`) fire
  in fast context. Buffer writes, most `vim.api.*` calls, and
  `Logger.notify` from those callbacks crash with a fast-context
  error. Wrap their bodies in `vim.schedule`.
  `session_manager._handle_input_submit` already does this for the
  `send_prompt` response.
- Session-update notifications already cross the `vim.schedule`
  boundary inside `ACPClient`, so subscribers (`SessionManager:_on_*`)
  run on the main loop. No extra `vim.schedule` needed there.
- `vim.schedule` preserves FIFO order: subscribers see notifications
  in the order the provider sent them, even when one libuv read
  delivers many messages at once. No batching, no reordering. If the
  UI ever appears to "batch" updates after a delay, the buffering is
  upstream (provider stdout), not here.

Why preserved:

- Wrapping the RPC branch in `vim.schedule` too would defer the
  `initialize` handler that flips state to `ready` and drains
  `ready_listeners`. Deferring it lets notifications that arrive in
  the same libuv read observe `state == "initializing"` and behave
  inconsistently.
- Running the notification branch synchronously would put UI writes
  (`MessageWriter:write_message_chunk` calls `nvim_buf_set_text`)
  into fast context and crash.

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
| `"request_permission"`  | `PermissionManager` (concurrent map)       |
| others                  | `subscriber.on_session_update()` (generic) |

## Tool call lifecycle

Tool calls go through **3 phases**. `MessageWriter` tracks each via
`tool_call_blocks[tool_call_id]`, persisting state across all phases.

**Phase 1 — `tool_call` (initial)**

```mermaid
flowchart TD
    P["Provider sends 'tool_call'"]
    B["ACPClient.__build_tool_call_message<br/>builds ToolCallBlock<br/>{ tool_call_id, kind, argument,<br/>status, body?, diff? }"]
    S["subscriber.on_tool_call(block)"]
    W["MessageWriter:write_tool_call_block(block)"]
    W1["1. Render header + body/diff lines"]
    W2["2. Create range extmark<br/>(NS_TOOL_BLOCKS) as anchor"]
    W3["3. Statuscolumn reads extmark for borders<br/>status footer extmark renders icon"]
    W4["4. Store block in tool_call_blocks[id]"]

    P --> B --> S --> W
    W --> W1 --> W2 --> W3 --> W4
```

**Phase 2 — `tool_call_update` (one or more)**

```mermaid
flowchart TD
    P["Provider sends 'tool_call_update'"]
    B["ACPClient.__build_tool_call_message<br/>builds ToolCallBase<br/>(only CHANGED fields — MessageWriter merges)"]
    S["subscriber.on_tool_call_update(partial)"]
    W["MessageWriter:update_tool_call_block(partial)"]
    W1["1. tracker = tool_call_blocks[id]"]
    W2["2. tbl_deep_extend('force', tracker, partial)"]
    W3["3. Append body if old/new exist and differ"]
    W4["4. Locate block via range extmark"]
    Diff{"diff already rendered?"}
    W5a["5a. Refresh header + status only<br/>(content frozen, no flicker)"]
    W5b["5b. Replace buffer lines, re-render all"]

    P --> B --> S --> W
    W --> W1 --> W2 --> W3 --> W4 --> Diff
    Diff -->|yes| W5a
    Diff -->|no, diff is new| W5b
```

**Phase 3 — final `tool_call_update` with terminal status**

```mermaid
flowchart TD
    P["Same as Phase 2, but status = 'completed' | 'failed'"]
    I["Visual status icon updates to final state"]
    F{"status == 'failed'?"}
    R["PermissionManager removes pending request"]
    N["no-op"]

    P --> I --> F
    F -->|yes| R
    F -->|no| N
```

## Key design rules

- **Updates are partial:** Only send what changed. MessageWriter merges onto the
  existing tracker via `tbl_deep_extend`.
- **Diffs are immutable after first render:** Once a diff is written to the
  buffer, content is frozen. Only header/status refresh on subsequent updates.
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

```mermaid
flowchart TD
    P["Provider sends 'session/request_permission'"]
    C["ACPClient.__handle_request_permission<br/>emits request.toolCall as tool_call_update"]
    PH["SessionManager:_on_tool_call_update<br/>routes missing tracker to first render"]
    W["MessageWriter:write_tool_call_block<br/>defaults missing fields to<br/>other(Pending) pending"]
    SM["SessionManager<br/>opens diff preview if request carries a diff"]
    PM["PermissionManager:add_request(request, callback)"]
    Store["Store in pending[tool_call_id]<br/>append to insertion order"]
    F{"first pending?"}
    Focus["_set_focus -> install digit keymaps,<br/>jump cursor, paint focused row N"]
    Paint["paint non-focused row N (buttons inactive)"]
    U["User presses 1/2/3/4 (digit)"]
    Cyc["User presses cycle_next / cycle_prev<br/>(default <C-n> / <C-p>)"]
    Cycle["_cycle_focus -> repaint old + new row N"]
    Res["resolve(focused_id, option_id)"]
    CB["callback(option_id), provider notified"]
    Clear["Clear diff preview"]
    Next{"more pending?"}
    Adv["_set_focus(next head)"]
    Done["idle"]

    P --> C --> PH --> W --> SM --> PM --> Store --> F
    F -->|yes| Focus
    F -->|no| Paint
    Focus --> U
    Paint --> U
    U --> Res --> CB --> Clear --> Next
    Next -->|yes| Adv --> U
    Next -->|no| Done
    Cyc --> Cycle --> U
```

Multiple permission requests can be pending concurrently (one per tool call).
Focus tracks the queue head (oldest pending); new arrivals do not steal focus.
Requests that arrive before their `tool_call` notification are normalized by
the first-render path: `SessionManager:_on_tool_call_update` routes a missing
tracker through `MessageWriter:write_tool_call_block`, which defaults missing
kind/title/status to `other(Pending)` + `pending`. This creates row N before
`PermissionManager:add_request` paints buttons, without overwriting partial
updates on existing blocks. Regression:
`lua/agentic/ui/message_writer.test.lua::"defaults missing initial tool call fields before render"`.

Digit keys `1`..`4` dispatch the focused block's option;
`Config.keymaps.permission.cycle_next` / `cycle_prev` (default `<C-n>` /
`<C-p>`) cycle focus between pending blocks. `h` / `l` / `<Left>` / `<Right>`
cycle the focused button within the block; `<CR>` submits it. All per-block
keys fire only when the cursor is on the focused block's row N (off-row keys
fall through to normal behavior).

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

## Provider switch (UI-only history replay)

`init.lua::apply_provider_switch` destroys the current **SessionManager**,
swaps `Config.provider`, creates a new `AgentInstance` / **ACP Session**, and
then calls `MessageWriter:replay_history_messages` to repaint the chat buffer
from the prior session's history.

The new provider receives ZERO prior context: no `send_prompt` re-injection,
no bulk history payload. The replay is a UI repaint only.

Do NOT add a fallback that lazily re-sends history to the new provider
without an explicit user opt-in — it would silently double-bill tokens and
change perceived behavior.

## Modes, models, thought level (config options dispatch)

`SessionManager:new_session` dispatches on `SessionCreationResponse`:

- `response.configOptions` present -> new path, handled by
  `AgentConfigOptions:_handle_new_config_options`.
- otherwise -> legacy path, `response.modes` populates `AgentModes` and
  `response.models` populates `AgentModels`.

The new path subsumes the legacy fields; both paths are kept because some
providers still send only `modes`/`models`.

Selectors are keymap-driven (`Config.keymaps.widget.change_mode`,
`switch_model`, `change_thought_level`) and use `vim.ui.select`. No public
`init.lua` entry exists for these — direct access is by keymap only.

## Subprocess lifecycle

Every ACP child is spawned with `uv.spawn({ detached = true })` so it leads
its own session/process group. `transport:stop` signals the whole group via
`uv.kill(-pid, 15)` then `uv.kill(-pid, 9)` on POSIX (Windows falls back to
`process:kill`). This catches wrappers that don't forward signals (e.g.
`codex-acp.js` uses `spawnSync` with no signal handlers, otherwise its native
grandchild leaks as `PPID 1`). Trade-off: children outlive a hard `kill -9` of
nvim. See ADR 0006. Regression:
``lua/agentic/acp/acp_transport.test.lua::"kills descendant processes when wrapper does not forward signals"``.

## Reconnect

`ACPProviderConfig.reconnect` (boolean, default `false`) opts a provider into
process-exit reconnection. The transport's `on_state_change("disconnected")`
defers 2s and re-spawns up to `max_reconnect_attempts` times (default 3).

`_drain_pending_callbacks` rejects every pending RPC with `TRANSPORT_ERROR`
on each `disconnected` / `error` transition, so reconnect does not silently
strand callers — they see the rejection, the next `send_prompt` succeeds
against the re-spawned process if reconnect lands.

No provider has `reconnect = true` in `Config.acp_providers` defaults; users
opt in per-provider in their `setup`.
