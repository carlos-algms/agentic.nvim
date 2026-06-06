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

## Protocol flow details

The full event pipeline, ACPClient lifecycle, stdio framing, sync/async
dispatch rules, session-update routing, tool-call lifecycle, permission flow,
provider switch behavior, config option dispatch, subprocess lifecycle, and
reconnect invariants live in the `agentic-acp-protocol-flow` skill.
