---
name: agentic-acp-docs-and-schema
description:
  Use when ACP schema is necessary to clarify the work or when the user asks for
  ACP data, rules, events, or documentation
---

# ACP documentation and schema

The ACP documentation can be found at:

- Complete Schema: https://agentclientprotocol.com/protocol/schema.md
- Overview: https://agentclientprotocol.com/protocol/overview.md
- Initialization: https://agentclientprotocol.com/protocol/initialization.md
- Session Setup: https://agentclientprotocol.com/protocol/session-setup.md
- https://agentclientprotocol.com/protocol/session-config-options.md
- Prompt Turn: https://agentclientprotocol.com/protocol/prompt-turn.md
- Content: https://agentclientprotocol.com/protocol/content.md
- Tool Calls: https://agentclientprotocol.com/protocol/tool-calls
- File System: https://agentclientprotocol.com/protocol/file-system.md
- Terminals: https://agentclientprotocol.com/protocol/terminals.md
- Agent Plan: https://agentclientprotocol.com/protocol/agent-plan.md
- Session Modes: https://agentclientprotocol.com/protocol/session-modes.md
- Slash Commands: https://agentclientprotocol.com/protocol/slash-commands.md
- Extensibility: https://agentclientprotocol.com/protocol/extensibility.md
- Transports: https://agentclientprotocol.com/protocol/transports.md

## ACP architectural limitations:

- **No partial acceptance of file changes:** Users must accept or reject the
  entire file's changes as a unit. The ACP protocol is async and transactional
  (all-or-nothing tool calls). Implementing partial acceptance would require
  complex workarounds (e.g., auto-accepting then partially reverting) which adds
  significant complexity. This feature is deferred/out of scope.

## Message flow and tool call lifecycle

Required reading for working on adapters, `MessageWriter`, `SessionManager`, or
`PermissionManager`.
