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

Load the `agentic-acp-protocol-flow` skill before editing `ACPClient`,
`ACPTransport`, `AgentInstance`, ACP provider flow, tool-call parsing,
permission requests, provider switch, reconnect, or ACP subprocess lifecycle.
For schema facts, also load `agentic-acp-docs-and-schema`.

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

## A request handler MUST always answer; a notification handler need not

`ACPClient:_handle_notification` dispatches two shapes of inbound JSON-RPC
message, and they carry opposite obligations:

- A **notification** (`session/update`) has no `id`. Nothing is waiting on it, so
  dropping it when the subscriber is gone is correct.
- A **request** (`session/request_permission`) has an `id`. The provider blocks
  until that `id` is answered, and the subprocess is **shared across every
  session** (ADR 0004), so one unanswered request hangs the agent for all of them.
  Every exit path owes a `__send_result`.

`ACPClient:__with_subscriber` therefore takes an `on_missing` callback:

```lua
--- @param on_missing fun()|nil Runs when no subscriber answers
function ACPClient:__with_subscriber(session_id, callback, on_missing)
```

It fires on **both** misses — the synchronous one (no subscriber when the message
arrives) and the deferred one (the subscriber was dropped while the `vim.schedule`
body sat in the queue). The subscriber is re-resolved **inside** the schedule for
exactly that reason; `cancel_session` nils it mid-flight.

Only `__handle_request_permission` passes `on_missing`, answering
`{ outcome = "cancelled" }`. The three notification call sites pass nothing and
keep returning silently.

Regression:
`lua/agentic/acp/acp_client.test.lua::"answers cancelled when the subscriber is gone"`.

### The dispatch body MUST answer even when it throws

A missing subscriber is not the only way to strand the `id`. The pre-dispatch
type guard in `__handle_request_permission` only validates the payload's **top
level**; everything below it runs unchecked inside the `vim.schedule` body, where
three reachable throws left the `id` unanswered:

- `subscriber.on_request_permission` throws (a UI defect)
- `subscriber.on_tool_call_update` throws (same)
- `__build_tool_call_message` throws on a payload the type guard accepts.
  `update.content` is type-checked but its **elements** are not, so
  `toolCall = { toolCallId = "t1", content = { 5 } }` indexes a number.

`vim.schedule` swallows the error, so the transport read loop survives — which is
why this failed silently rather than crashing. The shared subprocess (ADR 0004)
just waits, and every session hangs with it.

The dispatch body is therefore wrapped in a `pcall` that answers
`{ outcome = "cancelled" }` on failure. Two rules govern it:

- It MUST `Logger.notify` the error. A silent cancel hides genuine UI bugs in
  `on_request_permission` behind a permission prompt that merely "didn't appear".
- `answer` MUST be idempotent. The subscriber can invoke its callback and _then_
  throw; the `id` is already answered at that point, and a second `__send_result`
  on one `id` is a protocol violation. The guard's cancel is a no-op once
  answered, so a real `selected` outcome is never overwritten.

Do NOT harden `__build_tool_call_message` instead. One guard at the dispatch
boundary closes all three variants; hardening the builder is a larger diff for
the same bug and still would not cover a throwing subscriber callback.

Regressions:

- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when on_request_permission throws"`
- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when on_tool_call_update throws"`
- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when the nested tool call content is malformed"`
- `lua/agentic/acp/acp_client.test.lua::"answers once when the handler answers and then throws"`

## Protocol flow details

The full event pipeline, ACPClient lifecycle, stdio framing, sync/async
dispatch rules, session-update routing, tool-call lifecycle, permission flow,
provider switch behavior, config option dispatch, subprocess lifecycle, and
reconnect invariants live in the `agentic-acp-protocol-flow` skill.
