# Agents Guide

agentic.nvim is a Neovim plugin that emulates Cursor AI IDE behavior, providing
AI-driven code assistance through a chat sidebar for interactive conversations.

## Development & Linting

Quick syntax check:

```bash
luac -p <file> [<file2> ...]  # Parse only, checks for syntax errors without compilation
```

Examples:

```bash
luac -p lua/agentic/init.lua                    # Single file
luac -p lua/agentic/init.lua lua/agentic/ui.lua # Multiple files
luac -p lua/agentic/*.lua                       # Using glob patterns
```

Or with Make for running Lua linting and type checking tools:

### Available Make targets:

- `make luals` - Run Lua Language Server headless diagnosis (type checking)
- `make luacheck` - Run Luacheck linter (style and syntax checking)
- `make print-vimruntime` - Display the detected VIMRUNTIME path

### Tool overrides:

Override default tool paths if needed:

```bash
make NVIM=/path/to/nvim luals
make LUALS=/path/to/lua-language-server luals
make LUACHECK=/path/to/luacheck luacheck
```

**Note:** The `lua/agentic/acp/acp_client.lua` file contains critical type annotations for Lua Language Server support. These annotations should **never** be removed, only updated when the underlying types change.

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
  },
  ["claude-code"] = {
    command = "npx",
    args = { "@zed-industries/claude-code-acp" },
    env = { ANTHROPIC_API_KEY = "..." },
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

**IMPORTANT**: For dealing with neovim native features and APIs, refer to the
official docs:

- Neovim Lua API:
  https://raw.githubusercontent.com/neovim/neovim/refs/tags/v0.11.5/runtime/doc/api.txt
- Neovim Job Control:
  https://raw.githubusercontent.com/neovim/neovim/refs/tags/v0.11.5/runtime/doc/job_control.txt
- Neovim Diff:
  https://raw.githubusercontent.com/neovim/neovim/refs/tags/v0.11.5/runtime/doc/diff.txt
- Neovim Diagnostics:
  https://raw.githubusercontent.com/neovim/neovim/refs/tags/v0.11.5/runtime/doc/diagnostic.txt

Don't be limited to these docs, explore more as needed.

