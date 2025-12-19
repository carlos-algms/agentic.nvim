# Agentic.nvim

![PR Checks](https://github.com/carlos-algms/agentic.nvim/actions/workflows/pr-check.yml/badge.svg)

> ⚡ A blazingly fast Chat interface for ACP providers in Neovim

**Agentic.nvim** brings your AI assistant to Neovim through the implementation
of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

You'll get the same results and performance as you would when using the ACP
provider's official CLI directly from the terminal.

There're no hidden prompts or magic happening behind the scenes. Just a Chat
interface, your colors, and your keymaps.

## ✨ Features

- **⚡ Performance First** - Optimized for minimal overhead and fast response
  times
- **🔌 Multiple ACP Providers** - Support for Claude, Gemini, Codex, and
  OpenCode
- **🔑 Zero Config Authentication** - No API keys needed
  - **Keep you secrets secret**: run `claude /login`, or `gemini auth login`
    once and, if they're working on your Terminal, they will work automatically
    on Agentic.
- **📝 Context Control** - Add files and text selections to conversation context
  with one keypress
- **🛡️ Permission System** - Interactive approval workflow for AI tool calls,
  mimicking Claude-code's approach, with 1, 2, 3, ... one-key press for quick
  responses
- **🤖 🤖 Multiple agents** - Independent Chat sessions for each Neovim Tab let
  you have multiple agents working simultaneously on different tasks
- **🎯 Clean UI** - Sidebar interface with markdown rendering and syntax
  highlighting
- **⌨️ Slash Commands** - Native Neovim completion for ACP slash commands with
  fuzzy filtering
  - Every slash command your provider has access too will apear when you type
    `/` in the prompt as the first character
- **📁 File Picker** - Type `@` to trigger autocomplete for workspace files
  - Reference multiple files: `@file1.lua @file2.lua`
- **🔄 Agent Mode Switching** - Switch between ACP-supported agent modes with
  Shift-Tab (Similar to Claude, Gemini, Cursor-agent, etc)
  - `Default`, `Auto Accept`, `Plan mode`, etc... (depends on the provider)
- **ℹ️ Smart Context** - Automatically includes system and project information
  in the first message of each session, so the Agent don't spend time and tokens
  gathering basic info

## 🎥 Showcase

### Simple replace with tool approval:

https://github.com/user-attachments/assets/4b33bb18-95f7-4fea-bc12-9a9208823911

### 🐣 NEW: Switch agent mode: Always ask, Accept Edits, Plan mode...

https://github.com/user-attachments/assets/96a11aae-3095-46e7-86f1-ccc02d21c04f

### Add files to the context:

https://github.com/user-attachments/assets/b6b43544-a91e-407f-834e-4b4de41259f8

### Use `@` to fuzzy find any file:

https://github.com/user-attachments/assets/c6653a8b-20ef-49c8-b644-db0df1b342f0

## 📦 Installation

### lazy.nvim

```lua
{
  "carlos-algms/agentic.nvim",

  event = "VeryLazy",

  opts = {
    -- Available by default: "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp"
    provider = "claude-acp", -- setting the name here is all you need to get started
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

You don't have to copy and paste anything from the default config, linking it
here for ease access and reference:
[`lua/agentic/config_default.lua`](lua/agentic/config_default.lua).

### Customizing ACP Providers

You can customize the supported ACP providers by configuring the `acp_providers`
property:

> [!NOTE]  
> You don't have to override anything or include these in your setup.  
> This is only needed if you want to customize existing providers.

```lua
{
  acp_providers = {
    -- Override existing provider (e.g., add API key)
    -- Agentic.nvim don't require API keys, only add it if that's how you prefer to authenticate
    ["claude-acp"] = {
      env = {
        ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
      },
    },

    -- Example of how override the ACP command to suit your installation, if needed
    ["codex-acp"] = {
      command = "~/.local/bin/codex-acp",
    },
  },
}
```

**Provider Configuration Fields:**

- `command` (string) - The CLI command to execute (must be in PATH or absolute
  path)
- `args` (table, optional) - Array of command-line arguments
- `env` (table, optional) - Environment variables to set for the process

**Notes:** Customizing a provider only requires specifying the fields you want
to change, not the entire configuration.

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

> [!NOTE]  
> Why install ACP provider CLIs globally?
> [shai-hulud](https://www.wiz.io/blog/shai-hulud-2-0-ongoing-supply-chain-attack)
> should be reason enough. Pin your versions!  
> But frontend projects with strict package management policies will fail to
> start when using `npx ...`

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

### Built-in Keybindings

These keybindings are automatically set in Agentic buffers:

| Keybinding | Mode  | Description                                                   |
| ---------- | ----- | ------------------------------------------------------------- |
| `<S-Tab>`  | n/v/i | Switch agent mode (only available if provider supports modes) |
| `<CR>`     | n     | Submit prompt                                                 |
| `<C-s>`    | n/v/i | Submit prompt                                                 |
| `q`        | n     | Close chat widget                                             |
| `d`        | n     | Remove file or code selection at cursor                       |
| `d`        | v     | Remove multiple selected files or code selections             |

#### Customizing Keybindings

You can customize the default keybindings by configuring the `keymaps` option in
your setup:

```lua
{
  keymaps = {
    -- Keybindings for ALL buffers in the widget (chat, prompt, code, files)
    widget = {
      close = "q",  -- String for a single keybinding
      change_mode = {
        {
          "<S-Tab>",
          mode = { "i", "n", "v" },  -- Specify modes for this keybinding
        },
      },
    },

    -- Keybindings for the prompt buffer only
    prompt = {
      submit = {
        "<CR>",  -- Normal mode by default
        {
          "<C-s>",
          mode = { "n", "v", "i" },
        },
      },
    },
  },
}
```

**Keymap Configuration Format:**

- **String:** `close = "q"` - Simple keybinding (normal mode by default)
- **Array:** `submit = { "<CR>", "<C-s>" }` - Multiple keybindings (normal mode
  only)
- **Table with mode:** `{ "<C-s>", mode = { "i", "v" } }` - Keybinding with
  specific modes

The header text in the chat and prompt buffers will automatically update to show
the appropriate keybinding for the current mode.

### Slash Commands

Type `/` in the Prompt buffer to see available slash commands with
auto-completion.

The `/new` command is always available to start a new session, other commands
are provided by your ACP provider.

### File Picker

You can reference and add files to the context by typing `@` in the Prompt.  
It will trigger the native Neovim completion menu with a list of all files in
the current workspace.

- **Automatic scanning**: Uses `rg`, `fd`, `git ls-files`, or lua globs as
  fallback
- **Fuzzy filtering**: uses Neovim's native completion to filter results as you
  type
- **Multiple files**: You can reference multiple files in one prompt:
  `@file1.lua @file2.lua`

### System Information

Agentic automatically includes environment and project information in the first
message of each session:

- Platform information (OS, version, architecture)
- Shell and Neovim version
- Current date
- Git repository status (if applicable):
  - Current branch
  - Changed files
  - Recent commits (last 3)
- Project root path

This helps the AI Agent understand the context of the current project without
having to run additional commands or grep through files, the goals is to reduce
time for the first response.

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
{
  debug = true,

  --- ... rest of config
}
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

