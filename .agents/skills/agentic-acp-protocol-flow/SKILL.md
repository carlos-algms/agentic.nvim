---
name: agentic-acp-protocol-flow
description: >
  MANDATORY before editing ACPClient, ACPTransport, AgentInstance, ACP
  provider flow, tool-call parsing, permission requests, provider switch,
  reconnect, or ACP subprocess lifecycle in agentic.nvim.
---

# Agentic ACP Protocol Flow

Use this skill for ACP runtime behavior. For schema facts, also load
`agentic-acp-docs-and-schema`.

## Provider model

- External ACP CLI tools are spawned as subprocesses.
- The plugin does not install providers.
- All providers use the generic `ACPClient` in `acp_client.lua`.
- There are no per-provider adapter files. See ADR 0005.
- Add a provider with a `config_default.lua` entry under `acp_providers` unless
  the provider deviates from ACP in a new way.
- Provider quirks live in protected `ACPClient` methods, not adapter files.

## Pipeline

```text
provider subprocess
-> ACPTransport
-> ACPClient
-> SessionManager subscriber
-> MessageWriter / PermissionManager / TodoList / ChatHistory
```

## Load references by edit target

- `references/client-lifecycle.md`: `ACPClient.state`, ready listeners, sync vs
  async dispatch, reconnect, pending callback draining.
- `references/transport-framing.md`: stdio line framing, partial chunks,
  subprocess process-group termination.
- `references/tool-calls-permissions.md`: `session/update` routing, tool-call
  lifecycle, permission request normalization, provider quirks.
- `references/provider-switch-options.md`: provider switch replay, modes/models,
  thought level, config options.

## Protected methods

Current extension points:

| Method                        | Behavior                                  |
| ----------------------------- | ----------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock, notifies subscriber |
| `__build_tool_call_message`   | Parses ACP fields and quirk fallbacks     |
| `__handle_tool_call_update`   | Builds partial, notifies subscriber       |
| `__handle_request_permission` | Sends permission result to provider       |
| `__handle_session_update`     | Routes by `sessionUpdate` type            |

Only subclass or extend these when a real provider deviation requires it.

## Provider quirks

Handle protocol deviations inline in `__build_tool_call_message`.

- OpenCode `rawInput` fallback builds diffs when `content` is missing for edit
  tool calls.
- `locations` fallback extracts `file_path` from `update.locations[0].path`.
- Unknown tool kinds log a warning so users can report the provider behavior.
