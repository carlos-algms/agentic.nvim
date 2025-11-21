# Agentic.nvim

> ⚡ A blazingly fast Chat interface for ACP providers in Neovim

**Agentic.nvim** brings your AI assistant to Neovim through the implementation
of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

You should get the same results and performance as you would when using the ACP
provider's official CLI directly from the terminal.

There's no hidden prompts, or magic happening behind the scenes. Just the chat
sidebar and your colors, and your keymaps.

You don't have to leave Neovim, so more time in the
[Flow](<https://en.wikipedia.org/wiki/Flow_(psychology)>) state, and less
context switching.

## ✨ Features

- **⚡ Performance First** - Optimized for minimal overhead and fast response
  times
- **🔌 Multiple ACP Providers** - Support for Claude, Gemini, Codex, and
  OpenCode, and any other ACP-compliant provider
- **📝 Context Control** - Add files and text selections to conversation context
  with one keypress
- **🛡️ Permission System** - Interactive approval workflow for AI tool calls,
  mimicking Claude-code's approach, with 1, 2, 3, ... key bindings for quick
  responses
- **📂 Per-Tab Sessions** - Independent chat sessions for each Neovim tab allows
  yout to have multiple Agents working simultaneously
- **🎯 Clean UI** - Sidebar interface with markdown rendering and syntax
  highlighting

## 📋 Requirements

- **Neovim** v0.11.0 or higher
- **ACP Provider CLI** - At least one installed:

| Provider                           | Install                                                                                                                                 |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [claude-code-acp][claude-code-acp] | `npm i -g @zed-industries/claude-code-acp`<br/>`brew install --cask claude-code`<br/> `curl -fsSL https://claude.ai/install.sh \| bash` |
| [gemini-cli][gemini-cli]           | `npm i -g @google/gemini-cli`<br/>`brew install --cask gemini`                                                                          |
| [codex-acp][codex-acp]             | `npm i -g @zed-industries/codex-acp`<br/>`brew install --cask codex`<br/>[Download binary][codex-acp-releases]                          |
| [opencode][opencode]               | `npm i -g opencode-ai`<br/>`brew install opencode`<br/>`curl -fsSL https://opencode.ai/install \| bash`                                 |

**⚠️ NOTE:** these install commands are here for convenience, please always
refer to the official installation instructions from the respective ACP
provider.

## 📦 Installation

### lazy.nvim

```lua
{
  "carlos-algms/agentic.nvim",

  event = "VeryLazy",

  opts = {
    provider = "claude-acp", -- default provider
    acp_providers = {
      ["claude-acp"] = {
        env = {
          ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
        },
      },
    },
  },

  -- these are just suggested keymaps; customize as desired
  keys = {
    {
      "<C-\\>", function() require("agentic").toggle() end,
      mode = { "n", "v", "i" },
      desc = "Toggle Agentic Chat"
    },
    {
      "<C-'>",
      function() require("agentic").add_selection_or_file_to_context() end,
      mode = { "n", "v" },
      desc = "Add file or selection to Agentic to Context"
    },
    {
      "<C-,>",
      function() require("agentic").new_session() end,
      mode = { "n", "v", "i" },
      desc = "New Agentic Session"
    },
  },
}
```

## ⚙️ Configuration

You don't have to copy and paste it, just here for reference:

Click to expand:

<details>
<summary>
    <strong>Default Configuration</strong>
</summary>

```lua
require("agentic").setup({
  --- Enable printing debug messages which can be read via `:messages`
  debug = false,

  ---@type "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp"
  provider = "claude-acp",

  acp_providers = {
    ["claude-acp"] = {
      command = "claude-code-acp",
      env = {
        NODE_NO_WARNINGS = "1",
        IS_AI_TERMINAL = "1",
        ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
      },
    },

    ["gemini-acp"] = {
      command = "gemini",
      args = { "--experimental-acp" },
      env = {
        NODE_NO_WARNINGS = "1",
        IS_AI_TERMINAL = "1",
      },
    },

    ["codex-acp"] = {
      command = "codex-acp",
      args = {},
      env = {
        IS_AI_TERMINAL = "1",
      },
    },

    ["opencode-acp"] = {
      command = "opencode",
      args = { "acp" },
      env = {
        NODE_NO_WARNINGS = "1",
        IS_AI_TERMINAL = "1",
      },
    },
  },

  windows = {
    width = "40%", -- can be number (cols) or string (% of total width), or float (0.1 - 1.0)
    input = {
      height = 10, -- the height, in lines, of the prompt input area
    },
  },

  status_icons = {
    pending = "󰔛",
    completed = "✔",
    failed = "",
  },
})
```

</details>

## 🚀 Usage (Public Lua API)

### Commands

| Function                                                     | Description                                                     |
| ------------------------------------------------------------ | --------------------------------------------------------------- |
| `:lua require("agentic").toggle()`                           | Toggle chat sidebar                                             |
| `:lua require("agentic").open()`                             | Open chat sidebar (keep open if already visible)                |
| `:lua require("agentic").close()`                            | Close chat sidebar                                              |
| `:lua require("agentic").add_selection()`                    | Add visual selection to context                                 |
| `:lua require("agentic").add_file()`                         | Add current file to context                                     |
| `:lua require("agentic").add_selection_or_file_to_context()` | Add selection (if any) or file to the context                   |
| `:lua require("agentic").new_session()`                      | Start new chat session, destroying and cleaning the current one |

## 🔧 Development

### Debug Mode

Enable debug logging to troubleshoot issues:

```lua
require("agentic").setup({
  debug = true,

  --- ... rest of config
})
```

View logs with `:messages`

View messages exchanged with the ACP provider in the log file at:

- `~/.cache/nvim/agentic_debug.log`

## 📚 Resources

- [Agent Client Protocol Documentation](https://agentclientprotocol.com)
- [ACP Schema](https://agentclientprotocol.com/protocol/schema.md)

## 📄 License

[MIT License](LICENSE.txt)

## 🙏 Acknowledgments

- Built on top of the [Agent Client Protocol](https://agentclientprotocol.com)
  specification
- [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) - for
  being my entrance point of chatting with AI in Neovim
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) - for
  the buffer writing inspiration
- [avante.nvim](https://github.com/yetone/avante.nvim) - for the ACP client code
  and sidebar structured with multiple panels

[claude-code-acp]: https://www.npmjs.com/package/@zed-industries/claude-code-acp
[gemini-cli]: https://github.com/gemini-cli/gemini-cli
[codex-acp]: https://github.com/zed-industries/codex-acp
[codex-acp-releases]: https://github.com/zed-industries/codex-acp/releases
[opencode]: https://github.com/sst/opencode
