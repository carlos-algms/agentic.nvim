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
- **🔌 Multiple ACP Providers** - Support for Claude, Gemini, Codex, OpenCode,
  and Cursor Agent 🥇
- **🔑 Zero Config Authentication** - No API keys needed
  - **Keep you secrets secret**: run `claude /login`, or `gemini auth login`
    once and, if they're working on your Terminal, they will work automatically
    on Agentic.
- **📝 Context Control** - Add files and text selections to conversation context
  with one keypress
- **🏞️ Image Support** - Drag-and-drop or paste images and screenshots directly
  into the chat
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

### Image and Screenshot support in the Chat

https://github.com/user-attachments/assets/6ae57136-9c08-4d71-bc8a-59babc49be4d

### 🐣 NEW: Switch agent mode: Always ask, Accept Edits, Plan mode...

https://github.com/user-attachments/assets/96a11aae-3095-46e7-86f1-ccc02d21c04f

### Add files to the context:

https://github.com/user-attachments/assets/b6b43544-a91e-407f-834e-4b4de41259f8

### Use `@` to fuzzy find any file:

https://github.com/user-attachments/assets/c6653a8b-20ef-49c8-b644-db0df1b342f0

## 📋 Requirements

- **Neovim** v0.11.0 or higher
- **ACP Provider CLI** - Chose your favorite ACP and install its CLI tool
  - For security reasons, this plugin doesn't install or manage binaries for
    you. You must install them manually.

**We recommend using `pnpm`**  
`pnpm` uses a constant, static global path, that's resilient to updates.  
While `npm` loses global packages every time you change Node versions using
tools like `nvm`, `fnm`, etc...

**You are free to chose** any installation method you prefer!

| Provider                           | Install                                                                                                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [claude-code-acp][claude-code-acp] | `pnpm add -g @zed-industries/claude-code-acp`<br/> **OR** `npm i -g @zed-industries/claude-code-acp`<br/> **OR** [Download binary][claude-code-acp-releases]  |
| [gemini-cli][gemini-cli]           | `pnpm add -g @google/gemini-cli`<br/> **OR** `npm i -g @google/gemini-cli`<br/> **OR** `brew install --cask gemini`                                           |
| [codex-acp][codex-acp]             | `pnpm add -g @zed-industries/codex-acp`<br/> **OR** `npm i -g @zed-industries/codex-acp`<br/> **OR** [Download binary][codex-acp-releases]                    |
| [opencode][opencode]               | `pnpm add -g opencode-ai`<br/> **OR** `npm i -g opencode-ai`<br/> **OR** `brew install opencode`<br/> **OR** `curl -fsSL https://opencode.ai/install \| bash` |
| [cursor-agent][cursor-agent]       | `pnpm add -g @blowmage/cursor-agent-acp`<br/> **OR** `npm i -g @blowmage/cursor-agent-acp`                                                                    |

> [!WARNING]  
> These install commands are here for convenience, please always refer to the
> official installation instructions from the respective ACP provider.

> [!NOTE]  
> Why install ACP provider CLIs globally?
> [shai-hulud](https://www.wiz.io/blog/shai-hulud-2-0-ongoing-supply-chain-attack)
> should be reason enough. 📌 Pin your versions!  
> But frontend projects with strict package management policies will fail to
> start when using `npx ...`

## 📦 Installation

### lazy.nvim

```lua
{
  "carlos-algms/agentic.nvim",

  opts = {
    -- Available by default: "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp" | "cursor-acp"
    provider = "claude-acp", -- setting the name here is all you need to get started
  },

  -- these are just suggested keymaps; customize as desired
  keys = {
    {
      "<C-\\>",
      function() require("agentic").toggle() end,
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
> You don't have to override anything or include these in your setup!  
> These are just examples of how you can customize the commands, env, etc.

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    acp_providers = {
      -- Override existing provider (e.g., add API key)
      -- Agentic.nvim doesn't require API keys
      -- Only add it if that's how you prefer to authenticate
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
  },
}
```

**Provider Configuration Fields:**

- `command` (string) - The CLI command to execute (must be in PATH or absolute
  path)
- `args` (table, optional) - Array of command-line arguments
- `env` (table, optional) - Environment variables to set for the process
- `default_mode` (string, optional) - Default mode ID to set on session creation
  (e.g., `"bypassPermissions"`, `"plan"`)

> [!NOTE]  
> Customizing a provider only requires specifying the fields you want to
> override, not the entire configuration.

#### Setting a Default Agent Mode

If you prefer a specific agent mode other than the provider's default, you can
configure it per provider:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    acp_providers = {
      ["claude-acp"] = {
        -- Automatically switch to this mode when a new session starts
        default_mode = "bypassPermissions",
      },
    },
  },
}
```

The mode will only be set if it's available from the provider. Use `<S-Tab>` to
see available modes for your provider.

### Customizing Window Options

You can customize the behavior of individual chat widget windows by configuring
the `win_opts` property for each window. These options override the default
window settings.

### Customizing Window Headers

You can customize the header text for each panel in the chat widget using either
a table configuration or a custom render function.

#### Table-Based Configuration

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    headers = {
      chat = {
        title = "󰻞 My Custom Chat Title",
        suffix = "<S-Tab>: change mode",
      },
      -- ...
    },
  },
}
```

#### Function-Based Configuration

For complete control over header rendering, provide a function that receives the
header parts:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    headers = {
      chat = function(parts)
        local header = parts.title
        if parts.context then
          header = header .. " [" .. parts.context .. "]"
        end
        if parts.suffix then
          header = header .. " • " .. parts.suffix
        end
        return header
      end,
    },
  },
}
```

## 🚀 Usage (Public Lua API)

### Commands

| Function                                                     | Description                                                      |
| ------------------------------------------------------------ | ---------------------------------------------------------------- |
| `:lua require("agentic").toggle()`                           | Toggle chat sidebar                                              |
| `:lua require("agentic").open()`                             | Open chat sidebar (keep open if already visible)                 |
| `:lua require("agentic").close()`                            | Close chat sidebar                                               |
| `:lua require("agentic").add_selection()`                    | Add visual selection to context                                  |
| `:lua require("agentic").add_file()`                         | Add current file to context                                      |
| `:lua require("agentic").add_selection_or_file_to_context()` | Add selection (if any) or file to the context                    |
| `:lua require("agentic").new_session()`                      | Start new chat session, destroying and cleaning the current one  |
| `:lua require("agentic").stop_generation()`                  | Stop current generation or tool execution (session stays active) |

### Optional Parameters

Content-adding methods accept an optional `opts` table:

- **`focus_prompt`** (boolean, default: `true`) - Whether to move cursor to
  prompt input after opening the chat

Available on: `add_selection(opts)`, `add_file(opts)`,
`add_selection_or_file_to_context(opts)`

**Example:**

```lua
-- Add selection without focusing the prompt
require("agentic").add_selection({ focus_prompt = false })
```

### Built-in Keybindings

These keybindings are automatically set in Agentic buffers:

| Keybinding       | Mode  | Description                                                   |
| ---------------- | ----- | ------------------------------------------------------------- |
| `<S-Tab>`        | n/v/i | Switch agent mode (only available if provider supports modes) |
| `<CR>`           | n     | Submit prompt                                                 |
| `<C-s>`          | n/v/i | Submit prompt                                                 |
| `<localleader>p` | n/i   | Paste image from clipboard in the Prompt buffer               |
| `q`              | n     | Close chat widget                                             |
| `d`              | n     | Remove file or code selection at cursor                       |
| `d`              | v     | Remove multiple selected files or code selections             |

#### Customizing Keybindings

You can customize the default keybindings by configuring the `keymaps` option in
your setup:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
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
          "<CR>",  -- Normal mode, just Enter
          {
            "<C-s>",
            mode = { "n", "v", "i" },
          },
        },

        paste_image = {
          {
            "<localleader>p",
            mode = { "n", "i" }, -- I like normal and insert modes for this, but feel free to customize
          },
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

### Image and Screenshots support

You can drag-and-drop images into the Prompt buffer or paste images and
screenshots directly from your clipboard.

The support still depends on the ACP provider capabilities, but most of them
support images in the conversation.

Drag-and-drop should work out of the box if your terminal supports it, no need
for extra configuration or plugins.

But, if you want to paste screenshots directly from your clipboard, you'll need
to install the `img-clip.nvim` dependency:

```lua
{
  "carlos-algms/agentic.nvim",

  dependencies = {
    { "hakonharnes/img-clip.nvim", opts = {} }
  }

  -- ... rest of your config
}
```

Please note img-clip.nvim, on Linux depends on `xclip` (x11) or `wl-clipboard`
(wayland), or `pngpaste` on macOS, Windows requires no extra dependencies.

Then just press `<localleader>p` in the Prompt buffer to paste the image from
your clipboard.

NOTE: Due to Terminal and Neovim limitations, when pasting an image from the
Clipboard, there's no way of intercepting it, as it's considered binary and not
text, so either your Terminal or Neovim will just ignore and do nothing with it,
that's why we need the help of the external plugin. It's totally out of our
control.

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

### Event Hooks

Agentic.nvim provides hooks that let you respond to specific events during the
chat lifecycle. These are useful for logging, notifications, analytics, or
integrating with other plugins.

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    hooks = {
      -- Called when the user submits a prompt
      on_prompt_submit = function(data)
        -- data.prompt: string - The user's prompt text
        -- data.session_id: string - The ACP session ID
        -- data.tab_page_id: number - The Neovim tabpage ID
        vim.notify("Prompt submitted: " .. data.prompt:sub(1, 50))
      end,

      -- Called when the agent finishes responding
      on_response_complete = function(data)
        -- data.session_id: string - The ACP session ID
        -- data.tab_page_id: number - The Neovim tabpage ID
        -- data.success: boolean - Whether response completed without error
        -- data.error: table|nil - Error details if failed
        if data.success then
          vim.notify("Agent finished!", vim.log.levels.INFO)
        else
          vim.notify("Agent error: " .. vim.inspect(data.error), vim.log.levels.ERROR)
        end
      end,
    }
  }
}
```

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

### Health Check

Verify your installation and dependencies:

```vim
:checkhealth agentic
```

This will check:

- Neovim version (≥ 0.11.0 required)
- Current ACP provider installation (We don't install them for security reasons)
- Optional ACP providers (so you know which ones are available and can use at
  any time)
- Node.js and package managers (Most of the ACP CLIs require Node.js to install
  and run, some have native binaries too, we don't have control over that, it up
  to the Creators)

### Debug Mode

Enable debug logging to troubleshoot issues:

```lua
{
   "carlos-algms/agentic.nvim",
    opts = {
      debug = true,
      -- ... rest of your options
    }
}
```

View debug logs with `:messages` (lost after restarting Neovim)

View messages exchanged with the ACP provider in the log file at:  
(persistent until you delete it)

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

[claude-code-acp]: https://github.com/zed-industries/claude-code-acp
[claude-code-acp-releases]:
  https://github.com/zed-industries/claude-code-acp/releases
[gemini-cli]: https://github.com/gemini-cli/gemini-cli
[codex-acp]: https://github.com/zed-industries/codex-acp
[codex-acp-releases]: https://github.com/zed-industries/codex-acp/releases
[opencode]: https://github.com/sst/opencode
[cursor-agent]: https://github.com/blowmage/cursor-agent-acp-npm
