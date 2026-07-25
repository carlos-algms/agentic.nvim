# agentic.nvim

Domain glossary for agentic.nvim. Defines terms that are overloaded, ambiguous,
or unique to this project. Not a spec. Not a design doc. Implementation
details belong in `AGENTS.md` (rules) or `docs/adr/` (decisions).

## Language

### Process and protocol

**Provider**:
External CLI tool spawned as a subprocess (e.g. `claude-agent-acp`, `gemini`,
`codex-acp`). Speaks ACP over stdio.
_Avoid_: backend, server, model, agent (without qualifier).

**ACP (Agent Client Protocol)**:
Newline-delimited JSON-RPC protocol used to talk to a **Provider**.

**AgentInstance**:
The single, shared **ACPClient** held per **Provider** name. One subprocess per
provider, multiplexed across every **Session**.
_Avoid_: agent, client (use the precise term).

**ACPClient**:
The Lua object that owns one **Provider** subprocess and one **ACPTransport**.
Routes RPC responses and `session/update` notifications. One per
**AgentInstance**.

**ACPTransport**:
Stdio framing layer below **ACPClient**. Splits JSON-RPC by newlines, preserves
partial trailers.

**Subscriber**:
Per-`session_id` `ClientHandlers` table registered on `ACPClient.subscribers`.
In practice always the **SessionManager** for that **ACP Session**. `ACPClient`
routes notifications via `__with_subscriber(session_id, cb)`.
_Avoid_: "listener", "consumer".

### Session — the overloaded word

`Session` means three different things at three layers. Use the qualified term.

**ACP Session**:
A protocol-level session id, opaque string issued by the **Provider** via
`session/new`. One **AgentInstance** can hold many; this plugin activates one
per **SessionManager**.
_Avoid_: bare "session" when discussing protocol traffic.

**SessionManager**:
The Lua orchestrator for one conversation. Owns the **ChatWidget**, holds the
active **ACP Session** id, routes `session/update` events to the
**MessageWriter**, **PermissionManager**, and **ChatHistory**. The isolation
unit for this plugin.
_Avoid_: "the session" — say SessionManager.

**Session key**:
The integer **SessionRegistry** key, assigned at creation and stable for the
**SessionManager**'s whole life. The only stable identity a **Session** has;
published to users on every hook payload.
_Avoid_: keying anything off a **Tabpage** handle.

**SessionRegistry**:
The module-level singleton mapping **Session key** -> **SessionManager**. The
only sanctioned entry point from `init.lua`. `show_session` is the single path
that makes a **SessionManager** visible. See ADR 0008.

### Tabpage scope

**Tabpage**:
The Neovim tab. A **placement**, not an owner: at most one **ChatWidget** is
visible in a Tabpage, and at most one Tabpage shows a given **ChatWidget**.
Derived live from `ChatWidget:visible_tab()` and never stored.
_Avoid_: "tab" (ambiguous with terminal tabs and chat-buffer tabs).

**Background session**:
A **SessionManager** whose **ChatWidget** is visible in no Tabpage —
`visible_tab()` is nil. It keeps its **ACP Session**, keeps receiving
`session/update`, and keeps generating.
_Avoid_: "closed session"; closing a widget destroys nothing.

### UI surface

**ChatWidget**:
The UI container for one **SessionManager**. Owns five buffers (see **ChatWidget
buffers**), panel windows, autocmds, and the **MessageWriter**. Reachable from
any of its buffer numbers via **WidgetRegistry**.

**ChatWidget buffers**:
The five buffers held on `ChatWidget.buf_nrs`:

- `chat` — the streaming transcript. Owned by **MessageWriter**.
- `input` — user prompt entry buffer.
- `files` — backs the **FileList** view.
- `code` — backs the **CodeSelection** view.
- `diagnostics` — buffer-diagnostics view attached to the prompt.

When a doc says "chat buffer" it means `buf_nrs.chat` specifically. "Widget
buffer" means any of the five.

**WidgetLayout**:
Geometry/window management for **ChatWidget**. Opens, closes, resizes panels.
Applies `PANEL_WINDOW_OPTS` via `vim.wo[winid][0]`.

**Hidden chat float**:
Internal floating window holding the chat buffer while **ChatWidget** is
hidden. Preserves fold-state snapshots across hide/show. Not user-reachable.
See ADR 0001.

**BufferGuard**:
Redirects foreign buffers out of **ChatWidget** windows, into a non-widget
window in the **Tabpage** the owning widget is visible in. One shared augroup
for every widget; the owner is resolved through **WidgetRegistry**.

**WidgetRegistry**:
Module-level map from widget buffer number to owning **ChatWidget**. How
buffer-scoped code reaches its widget without storing a **Tabpage**. Buffer
numbers are global, so module-level state is correct here.

**WindowDecoration**:
Winbar text and buffer names. Header state lives on the owning **ChatWidget**
(`ChatWidget.headers`), resolved through **WidgetRegistry**.

**DiffPreview**:
Inline or split diff rendered in the real file buffer, NOT in the chat buffer.
Distinct from **ToolCallDiff** (which is rendered inside the chat buffer).

**MessageWriter**:
Owns the chat buffer content for one **ChatWidget**. Writes message chunks,
**Tool Call Blocks**, status rows. State machine for sender-header dedup,
auto-scroll capture/apply, thinking-block reuse.

**ChatHistory**:
Accumulates messages for persistence. Separate from on-screen buffer state.

**TodoList**:
Per-**ChatWidget** renderer for **Plan** events. Owns its own buffer in the
widget, separate from the chat buffer. Empty until first `plan` update.
_Avoid_: bare "todos" for the protocol event — that is **Plan**.

**FileList**:
Per-**ChatWidget** holder for files the user attached to the prompt. Owns its
own buffer; renders into the header via `on_change`.

**CodeSelection**:
Per-**ChatWidget** holder for code ranges the user attached to the prompt
(`agentic.Selection[]`). Sibling of **FileList**.

### Tool calls

**Tool Call**:
A provider-initiated action (file edit, bash, search, etc.) communicated via
`session/update` with `sessionUpdate = "tool_call"`. Goes through 3 phases:
initial, update(s), terminal.

**Tool Call Block**:
The rendered representation of a **Tool Call** in the chat buffer. Header +
top pad + body + bottom pad + status row N. Position tracked by a range
extmark in `NS_TOOL_BLOCKS`.
_Avoid_: "tool call" when discussing rendering — use Tool Call Block.

**ToolCallFold**:
Manual fold over a **Tool Call Block**'s body, anchored by the pad lines. See
ADR 0001.

**ToolCallDiff**:
Diff extracted from a **Tool Call** and rendered inside the chat buffer's
**Tool Call Block**. Immutable once rendered.

**ToolBlockBorder**:
`╭ │ ╰` glyphs drawn via `statuscolumn` to fence each **Tool Call Block**. See
ADR 0002.

**DiffHighlighter**:
Line and word highlighting for diffs rendered in the chat buffer.

### Permissions

**Permission Request**:
A provider-initiated `session/request_permission` event tied to a specific
**Tool Call** id. May carry a diff.

**PermissionManager**:
Per-**SessionManager** owner of pending **Permission Requests**, focus state,
per-block keymaps. Renders buttons inside the focused **Tool Call Block**. See ADR 0003.

### Message chunks

**Agent message chunk**:
Streaming chunk of the **Provider**'s primary response. `sessionUpdate =
"agent_message_chunk"`. Attributed to the `agent` sender.

**Agent thought chunk**:
Streaming chunk of the **Provider**'s internal reasoning. `sessionUpdate =
"agent_thought_chunk"`. Attributed to the `agent` sender. Reuses one extmark
in `NS_THINKING` across chunks.

**User message chunk**:
Echoed user input from the **Provider**. Attributed to the `user` sender.

**Plan**:
Provider-emitted todo list, rendered by `TodoList`. No sender header.

### Provider features (per session, keymap-driven)

**AgentConfigOptions**:
Per-**SessionManager** orchestrator for provider-side toggles (mode, model,
thought level). Reads `SessionCreationResponse.configOptions` (new path) or
`response.modes`/`response.models` (legacy path) at session creation. No
public `init.lua` entry — selectors open from configurable keymaps
(`change_mode`, `switch_model`, `change_thought_level`).

**AgentModes** / **AgentModels**:
Legacy-path holders inside `AgentConfigOptions`. Used when a provider sends
`modes`/`models` instead of unified `configOptions`. Same per-session scope.

**SlashCommands**:
Per-session input-buffer completion. Command list arrives via
`session/update` `available_commands_update` and is augmented locally: the
plugin filters out `clear` and auto-injects `/new` if absent. Only `/new` is
intercepted on submit (calls `new_session`); every other slash-prefixed line
is sent verbatim to the **Provider**.

### Hooks

**Hooks**:
User-registerable callbacks under `Config.hooks` (see
`config_default.lua`). All fire via `vim.schedule` + `pcall`. Every payload
carries the **Session key**. Six hooks today:

- `on_create_session_response` — fires after `session/new` returns.
- `on_prompt_submit` — fires when user submits a prompt.
- `on_response_complete` — fires when the agent finishes a turn.
- `on_session_update` — fires for every `session/update` notification.
- `on_file_edit` — fires when a file-mutating **Tool Call** completes
  (kinds: `edit`, `create`, `write`, `delete`, `move`). Skipped during
  session restore.
- `on_request_permission` — fires for each pending **Permission Request**.

### Reconnect

**Reconnect**:
Per-`ACPProviderConfig.reconnect` flag. Default `false`. Max 3 attempts at
2s backoff. Fires on provider process exit. No provider has it enabled by
default.

## Relationships

- A **SessionRegistry** maps each **Session key** to one **SessionManager**.
- A **SessionManager** owns one **ChatWidget** and references one **ACP
  Session** id on one **AgentInstance**.
- A **ChatWidget** is visible in at most one **Tabpage**, and a **Tabpage**
  shows at most one **ChatWidget**. Both may be zero.
- One **AgentInstance** per **Provider** name, shared across every
  **SessionManager**.
- A **ChatWidget** owns one **MessageWriter** which owns many **Tool Call
  Blocks** keyed by tool call id.
- A **Permission Request** belongs to exactly one **Tool Call** (by id) on
  exactly one **SessionManager**.
- **Tool Call Block**, **ToolCallFold**, **ToolCallDiff**, **ToolBlockBorder**
  all describe the same rendered block from different angles
  (content/folding/diff/borders).

## Example dialogue

> **Dev:** "When the user starts a second chat, do we spawn another
> **Provider**?"
> **Maintainer:** "No. **AgentInstance** is shared. We create a new **ACP
> Session** on the existing instance, and a new **SessionManager** owns it
> under its own **Session key**. Opening a **Tabpage** on its own creates
> nothing."

> **Dev:** "Where does the diff render — in the chat or in the file?"
> **Maintainer:** "Both, different things. **ToolCallDiff** renders inside the
> chat buffer's **Tool Call Block**. **DiffPreview** renders in the real file
> buffer."

## Flagged ambiguities

- "Session" was used to mean **ACP Session**, **SessionManager**, and
  **SessionRegistry** interchangeably. Resolved: three distinct concepts, use
  the qualified term.
- "Tabpage" was used as the ownership key: one **SessionManager** per tab, dying
  with it. Resolved: the **Session key** owns, the Tabpage only places. A
  Tabpage handle identifies nothing.
- "Agent" was used to mean **Provider** subprocess, **AgentInstance** Lua
  object, and the LLM behind the provider. Resolved: **Provider** for the
  subprocess, **AgentInstance** for the Lua holder; the LLM is not a domain
  concept here.
- "Tool call" was used to mean both the protocol event and its rendered block.
  Resolved: **Tool Call** for the event, **Tool Call Block** for the rendering.
- "Diff" was used to mean both the in-chat diff and the file-buffer preview.
  Resolved: **ToolCallDiff** (in-chat) vs **DiffPreview** (in-file).
- "Tracker" appears in `MessageWriter` code (`tracker.diff`,
  `tracker.permission`). Local-variable name, not a domain concept. Do not
  introduce it in docs.
- "Focus" was used to mean Neovim window focus and **PermissionManager** focus
  (which **Tool Call Block** has buttons active and digit keymaps bound).
  Resolved: bare "focus" = Neovim's window focus; "permission focus" or
  "focused block" for the **PermissionManager** notion.
- "status row", "status footer" refer to the same line: the last row of a
  **Tool Call Block**, outside the fold range. Canonical: **status row**.
  ("row N" was used pre-refactor and overlapped with the permission rows now
  rendered between `bottom_pad` and the status row; avoid the term.)
- "Functional test" vs "integration test" — `tests/AGENTS.md` once split these
  into separate categories with overlapping definitions. The split was not
  load-bearing. Resolved: treat as one category. Use either folder
  (`tests/functional/`, `tests/integration/`) when a test spans more than one
  module or needs real Neovim state across them; no formal distinction.
