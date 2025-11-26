# Agentic.nvim

> ⚡ A blazingly fast Chat interface for ACP providers in Neovim

**Agentic.nvim** brings your AI assistant to Neovim through the implementation
of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

You'll get the same results and performance as you would when using the ACP
provider's official CLI directly from the terminal.

There're no hidden prompts or magic happening behind the scenes. Just a chat
interface, your colors, and your keymaps.

You don't have to leave Neovim, so more time in the
[Flow](<https://en.wikipedia.org/wiki/Flow_(psychology)>) state and less context
switching, and less new tools and keymaps to learn.

https://github.com/user-attachments/assets/4b33bb18-95f7-4fea-bc12-9a9208823911

## ✨ Features

- **⚡ Performance First** - Optimized for minimal overhead and fast response
  times
- **🔌 Multiple ACP Providers** - Support for Claude, Gemini, Codex, OpenCode,
  and any other ACP-compliant provider
- **📝 Context Control** - Add files and text selections to conversation context
  with one keypress
- **🛡️ Permission System** - Interactive approval workflow for AI tool calls,
  mimicking Claude-code's approach, with 1, 2, 3, ... one-key press for quick
  responses
- **📂 Multiple agents** - Independent chat sessions for each Neovim Tab lets
  you have multiple agents working simultaneously on different tasks
- **🎯 Clean UI** - Sidebar interface with markdown rendering and syntax
  highlighting

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

You don't have to copy and paste it, it's just here for reference:

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
    width = "40%", -- can be number (cols), string (% of total width), or float (0.1 - 1.0)
    input = {
      height = 10, -- height in lines of the prompt input area
    },
  },

  spinner_chars = {
    generating = { "·", "✢", "✳", "∗", "✻", "✽" },
    thinking = { "🤔", "🤨", "😐" },
    searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
    busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
  },

  status_icons = {
    pending = "󰔛",    -- Icon shown for tool calls with pending status
    completed = "✔",   -- Icon shown for tool calls with completed status
    failed = "",      -- Icon shown for tool calls with failed status
  },


  permission_icons = {
    allow_once = "",
    allow_always = "",
    reject_once = "",
    reject_always = "󰜺",
  }
})
```

</details>

## 📋 Requirements

- **Neovim** v0.11.0 or higher
- **ACP Provider CLI** - Chose your favorite ACP and install its CLI tool

| Provider                           | Install                                                                                                                                 |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [claude-code-acp][claude-code-acp] | `npm i -g @zed-industries/claude-code-acp`<br/>`brew install --cask claude-code`<br/> `curl -fsSL https://claude.ai/install.sh \| bash` |
| [gemini-cli][gemini-cli]           | `npm i -g @google/gemini-cli`<br/>`brew install --cask gemini`                                                                          |
| [codex-acp][codex-acp]             | `npm i -g @zed-industries/codex-acp`<br/>`brew install --cask codex`<br/>[Download binary][codex-acp-releases]                          |
| [opencode][opencode]               | `npm i -g opencode-ai`<br/>`brew install opencode`<br/>`curl -fsSL https://opencode.ai/install \| bash`                                 |

> [!WARNING]  
> These install commands are here for convenience, please always refer to the
> official installation instructions from the respective ACP provider.

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

## 🍚 Customization (Ricing)

Agentic.nvim uses custom highlight groups that you can override to match your
colorscheme.

### Available Highlight Groups

| Highlight Group          | Purpose                                  | Default                             |
| ------------------------ | ---------------------------------------- | ----------------------------------- |
| `AgenticDiffDelete`      | Deleted lines in diff view               | Links to `DiffDelete`               |
| `AgenticDiffAdd`         | Added lines in diff view                 | Links to `DiffAdd`                  |
| `AgenticDiffDeleteWord`  | Word-level deletions in diff             | `bg=#9a3c3c, bold=true`             |
| `AgenticDiffAddWord`     | Word-level additions in diff             | `bg=#155729, bold=true`             |
| `AgenticStatusPending`   | Pending tool call status indicator       | `bg=#5f4d8f`                        |
| `AgenticStatusCompleted` | Completed tool call status indicator     | `bg=#2d5a3d`                        |
| `AgenticStatusFailed`    | Failed tool call status indicator        | `bg=#7a2d2d`                        |
| `AgenticCodeBlockFence`  | The left border decoration on tool calls | Links to `Directory`                |
| `AgenticTitle`           | Window titles in sidebar                 | `bg=#2787b0, fg=#000000, bold=true` |

If any of these highlight exists, Agentic will use it instead of creating new
ones.

## Integration with Lualine

If you're using [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) or
similar statusline plugins, configure it to ignore Agentic windows to prevent
conflicts with custom window decorations:

```lua
require('lualine').setup({
  options = {
    disabled_filetypes = {
      statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
      winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles' },
    }
  }
})
```

This ensures that Agentic's custom window titles and statuslines render
correctly without interference from your statusline plugin.

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

## 📄 License

[MIT License](LICENSE.txt)  
Feel free to copy, modify, and distribute, just be a good samaritan and include
the the acknowledgments 😊.

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
