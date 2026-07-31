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

## Protocol flow details

The full event pipeline, ACPClient lifecycle, stdio framing, sync/async
dispatch rules, session-update routing, tool-call lifecycle, permission flow,
provider switch behavior, config option dispatch, subprocess lifecycle, and
reconnect invariants live in the `agentic-acp-protocol-flow` skill.
