# Project Overview

agentic.nvim is a Neovim plugin that emulates Cursor AI IDE behavior, providing
AI-driven code assistance through a chat sidebar for interactive conversations.

### Provider System

#### ACP Providers (Agent Client Protocol)

These providers spawn **external CLI tools** as subprocesses and communicate via
the Agent Client Protocol:

- **Requirements**: External CLI tools must be installed
  - `brew install gemini-cli`
  - `npm -g install @zed-industries/claude-code-acp`
  - etc...

##### ACP provider configuration:

```lua
acp_providers = {
  ["gemini-cli"] = {
    command = "gemini",                    -- CLI command to spawn
    args = { "--experimental-acp" },       -- CLI arguments
    env = { GEMINI_API_KEY = "..." },      -- Environment variables
    auth_method = "gemini-api-key",        -- Auth method identifier
  },
  ["claude-code"] = {
    command = "npx",
    args = { "@zed-industries/claude-code-acp" },
    env = { ANTHROPIC_API_KEY = "..." },
    auth_method = "anthropic-api-key",
  },
}
```

The ACP documentation can be found at:

- Complete Schema: https://agentclientprotocol.com/protocol/schema.md
- Overview: https://agentclientprotocol.com/protocol/overview.md
- Initialization: https://agentclientprotocol.com/protocol/initialization.md
- Session Setup: https://agentclientprotocol.com/protocol/session-setup.md
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

## Plugin Requirements

- Neovim v0.11.0+ (make sure settings, functions, and APIs, specially around
  `vim.*` are for this version or newer)
