# Agentic.nvim

![PR Checks](https://github.com/carlos-algms/agentic.nvim/actions/workflows/pr-check.yml/badge.svg)

> ⚡ A Chat interface for AI agents in Neovim that works with any provider
> supporting the [Agent Client Protocol (ACP)](https://agentclientprotocol.com)
> — including Claude, Gemini, Codex, OpenCode, Cursor Agent, Copilot, Auggie,
> Mistral Vibe, Cline, Goose, and more.

**Agentic.nvim** brings your AI assistant to Neovim through the implementation
of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com).

You'll get the same results and performance as you would when using the ACP
provider's official CLI directly from the terminal.

Agentic.nvim is the interface, your agent is the Brain. This plugin will use all
the same configurations and authentication methods you already have set up on
your terminal.

Including your MCP servers, commands, SKILLs, and sub-agents, you don't have to
recreate your configuration to use Agentic.nvim.

You can start your work in Neovim, close it, and continue from the terminal, or
restore previous Neovim sessions using Agentic's built-in session persistence
feature.

There're no hidden prompts or magic happening behind the scenes. Just a Chat
interface, your colors, and your keymaps.

## Supported providers

Works with **any** AI provider that implements the
[Agent Client Protocol](https://agentclientprotocol.com), including, but not
limited to:

<table>
  <tr>
    <td align="center" width="130">
      <img src=".github/assets/images/claude.svg" width="48" height="48" alt="Claude"><br>
      <b>Claude</b>
    </td>
    <td align="center" width="130">
      <img src=".github/assets/images/gemini.svg" width="48" height="48" alt="Gemini"><br>
      <b>Gemini</b>
    </td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/openai-light.svg">
        <img src=".github/assets/images/openai.svg" width="48" height="48" alt="Codex">
      </picture><br>
      <b>Codex</b>
    </td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/opencode-light.svg">
        <img src=".github/assets/images/opencode.svg" width="48" height="48" alt="OpenCode">
      </picture><br>
      <b>OpenCode</b>
    </td>
  </tr>
  <tr>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/cursor-light.svg">
        <img src=".github/assets/images/cursor.svg" width="48" height="48" alt="Cursor">
      </picture><br>
      <b>Cursor</b>
    </td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/copilot-light.svg">
        <img src=".github/assets/images/copilot.svg" width="48" height="48" alt="Copilot">
      </picture><br>
      <b>Copilot</b>
    </td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/augment-light.svg">
        <img src=".github/assets/images/augment.svg" width="48" height="48" alt="Augment">
      </picture><br>
      <b>Augment</b>
    </td>
    <td align="center" width="130">
      <img src=".github/assets/images/mistral.svg" width="48" height="48" alt="Mistral Vibe"><br>
      <b>Mistral Vibe</b>
    </td>
  </tr>
  <tr>
    <td width="130"></td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/cline-light.svg">
        <img src=".github/assets/images/cline.svg" width="48" height="48" alt="Cline">
      </picture><br>
      <b>Cline</b>
    </td>
    <td align="center" width="130">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset=".github/assets/images/goose-light.svg">
        <img src=".github/assets/images/goose.svg" width="48" height="48" alt="Goose">
      </picture><br>
      <b>Goose</b>
    </td>
    <td width="130"></td>
  </tr>
</table>

_...and any future ACP-compatible provider._

## ✨ Features

- **⚡ Performance First** - Optimized for minimal overhead and fast response
  times
- **🔌 Any ACP Provider** - Works with any AI provider that implements the Agent
  Client Protocol — Claude, Gemini, Codex, OpenCode, Cursor Agent, Copilot,
  Auggie, Mistral Vibe, Cline, Goose, and any future ACP-compatible provider
- **🔑 Zero Config Authentication** - No API keys needed
  - **Keep you secrets secret**: run `claude /login`, or `gemini auth login`
    once and, if they're working on your Terminal, they will work automatically
    on Agentic.
- **🧠 Model Switcher** - Switch between available models mid-session
  (`<localLeader>m` in the chat widget)
- **🔀 Switch Providers** - Switch between ACP providers mid-conversation
  without losing chat history (`<localLeader>s` in the chat widget)
- **♻️ Session Restore** - Restore your session and chat history at any time,
  for all providers
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

### Rich diff preview

When editing files, if your provider asks for permission, you can see a diff
preview side-by-side or inline, set your preference in your options:

| Side-by-side                                          | Inline                                    |
| ----------------------------------------------------- | ----------------------------------------- |
| ![Side-by-side diff][preview-diff-side-by-side-image] | ![Inline diff][preview-diff-inline-image] |

### Dynamic layout rotation: right - bottom - left

https://github.com/user-attachments/assets/000c5a9a-5469-44e3-b302-4074caa58fa9

### Image and Screenshot support in the Chat

Drag-n-Drop or paste an image from the Clipboard directly to the chat context:

https://github.com/user-attachments/assets/6ae57136-9c08-4d71-bc8a-59babc49be4d

### Session restoration

Continue from where you left off, available for all providers!

<img width="1274" height="716" alt="Agentic-session-restore" src="https://github.com/user-attachments/assets/736c514a-003a-4984-89f5-0107ede259ce" />

### 🐣 NEW: Switch agent mode: Always ask, Accept Edits, Plan mode...

https://github.com/user-attachments/assets/96a11aae-3095-46e7-86f1-ccc02d21c04f

### Add files to the context:

Add the current file to the Chat context or the selected text, let your agent
know where you want it to work.

https://github.com/user-attachments/assets/b6b43544-a91e-407f-834e-4b4de41259f8

### Use `@` to fuzzy find any file:

https://github.com/user-attachments/assets/c6653a8b-20ef-49c8-b644-db0df1b342f0

## 📋 Requirements

- **Neovim** v0.11.0 or higher
- **ACP Provider CLI** - Install the CLI for any ACP-compatible provider of your
  choice
  - For security reasons, this plugin doesn't install or manage binaries for
    you. You must install them manually.

**We recommend using `pnpm`**  
`pnpm` uses a constant, static global path, that's resilient to updates.  
While `npm` loses global packages every time you change Node versions using
tools like `nvm`, `fnm`, etc...

**You are free to chose** any installation method you prefer!

| Provider                             | Install                                                                                                                                                                                        |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [claude-agent-acp][claude-agent-acp] | `pnpm add -g @zed-industries/claude-agent-acp`<br/> **OR** `npm i -g @zed-industries/claude-agent-acp`<br/> **OR** [Download binary][claude-agent-acp-releases]                                |
| [gemini-cli][gemini-cli]             | `pnpm add -g @google/gemini-cli`<br/> **OR** `npm i -g @google/gemini-cli`<br/> **OR** `brew install --cask gemini`                                                                            |
| [codex-acp][codex-acp]               | `pnpm add -g @zed-industries/codex-acp`<br/> **OR** `npm i -g @zed-industries/codex-acp`<br/> **OR** [Download binary][codex-acp-releases]                                                     |
| [opencode][opencode]                 | `pnpm add -g opencode-ai`<br/> **OR** `npm i -g opencode-ai`<br/> **OR** `brew install opencode`<br/> **OR** `curl -fsSL https://opencode.ai/install \| bash`                                  |
| [cursor-agent][cursor-agent-docs]    | `curl https://cursor.com/install -fsS \| bash` **OR** windows: `irm 'https://cursor.com/install?win32=true' \| iex`<br/> **OR** See [Cursor docs][cursor-agent-docs]                           |
| [copilot-cli][copilot-cli]           | `pnpm add -g @github/copilot`<br/> **OR** `npm i -g @github/copilot`<br/> **OR** `brew install copilot-cli`<br/> **OR** `curl -fsSL https://gh.io/copilot-install \| bash`                     |
| [auggie][auggie]                     | `pnpm add -g @augmentcode/auggie`<br/> **OR** `npm i -g @augmentcode/auggie`<br/> **OR** See [Auggie docs][auggie-docs]                                                                        |
| [mistral-vibe][mistral-vibe]         | `curl -LsSf https://mistral.ai/vibe/install.sh \| bash`<br/> **OR** `uv tool install mistral-vibe`<br/> **OR** `pip install mistral-vibe`<br/> **OR** [Download binary][mistral-vibe-releases] |
| [cline][cline]                       | `pnpm add -g cline`<br/> **OR** `npm i -g cline`<br/> **OR** See [Cline docs][cline-docs]                                                                                                      |
| [goose][goose]                       | `brew install block-goose-cli`<br/> **OR** See [Goose docs][goose-docs]                                                                                                                        |

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
    -- Any ACP-compatible provider works. Built-in: "claude-agent-acp" | "gemini-acp" | "codex-acp" | "opencode-acp" | "cursor-acp" | "copilot-acp" | "auggie-acp" | "mistral-vibe-acp" | "cline-acp" | "goose-acp"
    provider = "claude-agent-acp", -- setting the name here is all you need to get started
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
    {
      "<A-i>r", -- ai Restore
      function()
          require("agentic").restore_session()
      end,
      desc = "Agentic Restore session",
      silent = true,
      mode = { "n", "v", "i" },
    },
    {
      "<leader>ad", -- ai Diagnostics
      function()
          require("agentic").add_current_line_diagnostics()
      end,
      desc = "Add current line diagnostic to Agentic",
      mode = { "n" },
    },
    {
      "<leader>aD", -- ai all Diagnostics
      function()
          require("agentic").add_buffer_diagnostics()
      end,
      desc = "Add all buffer diagnostics to Agentic",
      mode = { "n" },
    },
  },
}
```

## ⚙️ Configuration

You don't have to copy and paste anything from the default config, linking it
here for ease access and reference:
[`lua/agentic/config_default.lua`](lua/agentic/config_default.lua).

### Customizing ACP Providers

You can customize the built-in providers or add any new ACP-compatible provider
by configuring the `acp_providers` property:

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
      ["claude-agent-acp"] = {
        env = {
          ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
        },
      },

      -- Example of how override the ACP command to suit your installation, if needed
      ["codex-acp"] = {
        command = "~/.local/bin/codex-acp",
      },

      -- Add any new ACP-compatible provider — the name and command are up to you
      ["my-cool-acp"] = {
        name = "My Cool ACP",
        command = "cool-acp",
        args = { "--mode", "acp" },
        env = {
          COOL_API_KEY = os.getenv("COOL_API_KEY"),
        },
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
      ["claude-agent-acp"] = {
        -- Automatically switch to this mode when a new session starts
        default_mode = "bypassPermissions",
      },
    },
  },
}
```

The mode will only be set if it's available from the provider. Use `<S-Tab>` to
see available modes for your provider.

### Window Layout

Configure the widget layout position and sizing:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    windows = {
      position = "right",  -- "right", "left", or "bottom"
      width = "40%",       -- Sidebar width (position = "right" or "left")
      height = "30%",      -- Panel height (position = "bottom")
    },
  },
}
```

- `position` - Widget layout: `"right"` or `"left"` (vertical sidebar) or
  `"bottom"` (horizontal panel)
- `width` - Sidebar width when `position` is right or left (percentage, decimal,
  or absolute)
- `height` - Panel height when `position = "bottom"` (percentage, decimal, or
  absolute)

### Rotating Layouts dynamically at runtime

You can rotate between layouts, dynamically, without closing Neovim with
`rotate_layout()`:

```lua
-- Rotates through all three layouts: right → bottom → left → right ...
require("agentic").rotate_layout()

-- Rotates between right and bottom only
require("agentic").rotate_layout({ "right", "bottom" })

-- Rotates between right and left only
require("agentic").rotate_layout({ "right", "left" })
```

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

| Function                                                     | Description                                                       |
| ------------------------------------------------------------ | ----------------------------------------------------------------- |
| `:lua require("agentic").toggle()`                           | Toggle chat sidebar                                               |
| `:lua require("agentic").open()`                             | Open chat sidebar (keep open if already visible)                  |
| `:lua require("agentic").close()`                            | Close chat sidebar                                                |
| `:lua require("agentic").add_selection()`                    | Add visual selection to context                                   |
| `:lua require("agentic").add_file()`                         | Add current file to context                                       |
| `:lua require("agentic").add_selection_or_file_to_context()` | Add selection (if any) or file to the context                     |
| `:lua require("agentic").add_files_to_context(opts)`         | Add a list of file paths or buffer numbers to context             |
| `:lua require("agentic").add_current_line_diagnostics()`     | Add diagnostics at cursor line to context                         |
| `:lua require("agentic").add_buffer_diagnostics()`           | Add all diagnostics from current buffer to context                |
| `:lua require("agentic").new_session()`                      | Start new chat session, destroying and cleaning the current one   |
| `:lua require("agentic").stop_generation()`                  | Stop current generation or tool execution (session stays active)  |
| `:lua require("agentic").restore_session()`                  | Show session picker to restore a previous session and continue    |
| `:lua require("agentic").switch_provider()`                  | Switch ACP provider mid-session (shows picker, preserves history) |
| `:lua require("agentic").rotate_layout()`                    | Rotate window position through layouts (right → bottom → left)    |

### Optional Parameters

Open and Toggle supports optional parameter:

- **auto_add_to_context** (boolean, default: `true`) - Whether to automatically
  add the current visual selection or file to context when opening the Chat

```lua
-- Open the chat without adding anything to context
require("agentic").open({ auto_add_to_context = false })
```

When adding files or selections to context, you can also specify whether to
focus the prompt input after opening the chat:

- **focus_prompt** (boolean, default: `true`) - Whether to move cursor to prompt
  input after opening the chat

Available on: `add_selection(opts)`, `add_file(opts)`,
`add_selection_or_file_to_context(opts)`, `add_files_to_context(opts)`,
`add_current_line_diagnostics(opts)`, `add_buffer_diagnostics(opts)`

```lua
-- Add selection without focusing the prompt
require("agentic").add_selection({ focus_prompt = false })
```

`add_files_to_context(opts)` accepts a **files** field with a list of file paths
(strings) or buffer numbers (integers). It can be used from anywhere, like your
file picker.

```lua
-- Add specific files by path
require("agentic").add_files_to_context({
  files = {
    "src/main.lua",
    "src/utils.lua",
  },
})

-- Add files by buffer number
require("agentic").add_files_to_context({
  files = { 1, 5 },
  focus_prompt = false,
})
```

### Built-in Keybindings

These keybindings are automatically set in Agentic buffers:

| Keybinding       | Mode  | Description                                                     |
| ---------------- | ----- | --------------------------------------------------------------- |
| `<S-Tab>`        | n/v/i | Switch agent mode (only available if provider supports modes)   |
| `<CR>`           | n     | Submit prompt                                                   |
| `<C-s>`          | n/v/i | Submit prompt                                                   |
| `<localLeader>p` | n     | Paste image from clipboard in the Prompt buffer                 |
| `<C-v>`          | i     | Paste image from clipboard (same as Claude-code)                |
| `<localLeader>s` | n     | Switch ACP provider (preserves chat history)                    |
| `<localLeader>m` | n     | Switch model without (preserves chat history)                   |
| `q`              | n     | Close chat widget                                               |
| `d`              | n     | Remove file, code selection, or diagnostic at cursor            |
| `d`              | v     | Remove multiple selected files, code selections, or diagnostics |
| `]c`             | n     | Navigate to next diff hunk (when diff preview is active)        |
| `[c`             | n     | Navigate to previous diff hunk (when diff preview is active)    |

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
        switch_provider = "<localLeader>s",  -- Switch ACP provider
        switch_model = "<localLeader>m",     -- Switch model
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
            "<localLeader>p",
            mode = { "n" },
          },
          {
            "<C-v>", -- Same as Claude-code in insert mode
            mode = { "i" },
          }
        },
      },

      -- Keybindings for diff preview navigation
      diff_preview = {
        next_hunk = "]c",
        prev_hunk = "[c",
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

### Diff Preview

When the agent makes file edits, agentic.nvim can show a preview of the changes
before you accept or reject them. You can configure the diff preview layout:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    diff_preview = {
      enabled = true,
      layout = "split",  -- "split" or "inline"
      center_on_navigate_hunks = true,
    },
  },
}
```

**Layout Options:**

- `"split"` (default) - Side-by-side diff view
- `"inline"` - Unified diff view in a single buffer

**Navigation:**

Use `]c` and `[c` to navigate between diff hunks (configurable).

**Note:** Changing the layout requires restarting Neovim.

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

### Session Persistence and Restoration

Agentic automatically saves your conversation history to disk, allowing you to
restore previous sessions across Neovim restarts at any time.

**Storage location:**

Default: `~/.cache/nvim/agentic/sessions/<normalized_project_path>/`

For example, if your project is at `/Users/me/projects/myapp`, sessions will be
stored in:  
`~/.cache/nvim/agentic/sessions/Users_me_projects_myapp_abc12345/`

The hash is to avoid collisions with projects with similar paths.

**Restoring sessions:**

Call `require("agentic").restore_session()` to:

1. See a list of all saved sessions for the current project
2. Sessions are displayed as: `YYYY-MM-DD HH:MM - <first user message>`
3. Select a session to restore the full conversation history

**Conflict handling:**

If you try to restore a session when the current tab already has an active
conversation, you'll be prompted to:

- Cancel the restoration (keep current session)
- Clear current session and restore the selected one

**Customizing storage location:**

You can change where sessions are stored:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    session_restore = {
      -- Custom storage path (default: nil uses ~/.cache/nvim/agentic/sessions/)
      storage_path = vim.fn.expand("~/OneDrive/agentic_sessions/"), -- for a cloud-synced folder for example
    },
  },
}
```

**What gets saved:**

- User prompts and agent responses
- Tool calls with their arguments and results
- Agent thinking/reasoning blocks
- Session metadata (timestamp, title)

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

      -- Called when the session is updated.
      on_session_update = function(data)
        -- data.session_id: string - The ACP session ID
        -- data.tab_page_id: number - The Neovim tabpage ID
        -- data.update: table -- The update

          if data.update.sessionUpdate == "usage_update" then
            -- Use this in your status line, scoped per tab/session.
            if vim.api.nvim_tabpage_is_valid(data.tab_page_id) then
              vim.t[data.tab_page_id].agentic_usage = {
                used = data.update.used,
                size = data.update.size,
              }
            end
          end
      end
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

### Customizing Diagnostic Icons

You can customize the icons used for diagnostics in the context panel:

```lua
{
  "carlos-algms/agentic.nvim",
  opts = {
    diagnostic_icons = {
      error = "❌",
      warn = "⚠️",
      info = "ℹ️",
      hint = "✨",
    },
  },
}
```

Default icons use emoji characters (❌, ⚠️, ℹ️, ✨) but you can use any string,
including Nerd Font icons or plain text.

## Integration with other Plugins

### Prompt suggestions with Copilot

To get Copilot suggestions while you are typing your prompt, you need to tell
Copilot to attach to the `AgenticInput` filetype.

#### copilot.vim

```lua
{
  "github/copilot.vim",
   -- ....
  init = function()
      vim.g.copilot_filetypes = {
          AgenticInput = true,
      }
  end,
}
```

#### copilot.lua

```lua
{
  "zbirenbaum/copilot.lua",
  -- ....
  opts = {
    -- Override should_attach to allow copilot in AgenticInput buffers
    -- AgenticInput uses buftype = "nofile" which copilot.lua rejects by default
    should_attach = function(bufnr, bufname)
      local filetype = vim.bo[bufnr].filetype

      if filetype == "AgenticInput" then
          return true
      end

      -- Delegate to default behavior for all other buffers
      local default_should_attach =
          require("copilot.config.should_attach").default
      return default_should_attach(bufnr, bufname)
    end,
  },
}
```

### Lualine

If you're using [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) or
similar statusline plugins, configure it to ignore Agentic windows to prevent
conflicts with custom window decorations:

```lua
require('lualine').setup({
  options = {
    disabled_filetypes = {
      statusline = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
      winbar = { 'AgenticChat', 'AgenticInput', 'AgenticCode', 'AgenticFiles', 'AgenticDiagnostics' },
    }
  }
})
```

This ensures that Agentic's custom window titles and statuslines render
correctly without interference from your statusline plugin.

### Markdown render plugins

Only the `AgenticChat` buffer is properly set as `markdown` and starts
Treesitter parser, you only need to mention it in your markdown render plugin
setup.

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  -- ...
  opts = {
    file_types = { "markdown", "md", "AgenticChat" },
  }
}
```

### Blink.cmp

You can disable `blink.cmp` from attaching to Agentic prompt buffers by adding
the following to your `blink.cmp` setup:

```lua
require('blink.cmp').setup({
  enabled = function()
    return not vim.tbl_contains({"AgenticInput"}, vim.bo.filetype)
  end,
})
```

### nvim-cmp

You can disable `nvim-cmp` from attaching to Agentic prompt buffers by using
filetype-specific setup or the `enabled` option:

```lua
-- Option 1: Filetype-specific setup (disable all sources)
require('cmp').setup.filetype('AgenticInput', {
  sources = {}
})

-- Option 2: Global enabled function
require('cmp').setup({
  enabled = function()
    return not vim.tbl_contains({"AgenticInput"}, vim.bo.filetype)
  end,
})
```

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

[claude-agent-acp]: https://github.com/zed-industries/claude-agent-acp
[claude-agent-acp-releases]:
  https://github.com/zed-industries/claude-agent-acp/releases
[gemini-cli]: https://github.com/gemini-cli/gemini-cli
[codex-acp]: https://github.com/zed-industries/codex-acp
[codex-acp-releases]: https://github.com/zed-industries/codex-acp/releases
[opencode]: https://github.com/sst/opencode
[cursor-agent-docs]: https://cursor.com/docs/cli/installation
[auggie]: https://www.npmjs.com/package/@augmentcode/auggie
[auggie-docs]: https://docs.augmentcode.com/cli/setup-auggie
[mistral-vibe]: https://github.com/mistralai/mistral-vibe
[mistral-vibe-releases]: https://github.com/mistralai/mistral-vibe/releases
[preview-diff-side-by-side-image]:
  https://github.com/user-attachments/assets/aef778af-815c-412b-a514-e3dec4280b6d
[preview-diff-inline-image]:
  https://github.com/user-attachments/assets/6f824ec9-023b-4cc4-aca6-647a6b191183
[copilot-cli]: https://github.com/github/copilot-cli
[cline]: https://github.com/cline/cline
[cline-docs]: https://docs.cline.bot/getting-started/installing-cline
[goose]: https://github.com/block/goose
[goose-docs]: https://block.github.io/goose/docs/getting-started/installation
