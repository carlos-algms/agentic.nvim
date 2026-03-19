--- @alias agentic.UserConfig.ProviderName
--- | "claude-acp"
--- | "claude-agent-acp"
--- | "gemini-acp"
--- | "codex-acp"
--- | "opencode-acp"
--- | "cursor-acp"
--- | "copilot-acp"
--- | "auggie-acp"
--- | "mistral-vibe-acp"
--- | "cline-acp"
--- | "goose-acp"

--- @alias agentic.UserConfig.HeaderRenderFn fun(parts: agentic.ui.ChatWidget.HeaderParts): string|nil

--- User config headers - each panel can have either config parts or a custom render function
--- Customize window headers for each panel in the chat widget.
--- Each header can be either:
--- 1. A table with title and suffix fields
--- 2. A function that receives header parts and returns a custom header string
---
--- The context field is managed internally and shows dynamic info like counts.
---
--- @alias agentic.UserConfig.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts|agentic.UserConfig.HeaderRenderFn|nil>

--- Data passed to the on_create_session_response hook
--- @class agentic.UserConfig.CreateSessionResponseData
--- @field session_id string|nil
--- @field tab_page_id number
--- @field response agentic.acp.SessionCreationResponse|nil
--- @field err? agentic.acp.ACPError

--- Data passed to the on_prompt_submit hook
--- @class agentic.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- Data passed to the on_response_complete hook
--- @class agentic.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed
---
--- Data passed to the on_session_update hook
--- @class agentic.UserConfig.SessionUpdateData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field update agentic.acp.SessionUpdateMessage ACP session update details.

--- Data passed to the on_file_edit hook
--- @class agentic.UserConfig.FileEditData
--- @field filepath string Absolute path to the edited file
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field bufnr? number Buffer number if the file is loaded in a buffer

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>
--- @field diff_preview table<string, string>

--- Window options passed to nvim_set_option_value
--- Overrides default options (wrap, linebreak, winfixheight)
--- @alias agentic.UserConfig.WinOpts table<string, any>

--- @class agentic.UserConfig.Windows.Chat
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Input
--- @field height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Code
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Files
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Diagnostics
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @class agentic.UserConfig.Windows.Todos
--- @field display boolean
--- @field max_height number
--- @field win_opts? agentic.UserConfig.WinOpts

--- @alias agentic.UserConfig.Windows.Position "right"|"left"|"bottom"

--- @class agentic.UserConfig.Windows
--- @field position agentic.UserConfig.Windows.Position
--- @field width string|number
--- @field height string|number
--- @field stack_width_ratio number
--- @field chat agentic.UserConfig.Windows.Chat
--- @field input agentic.UserConfig.Windows.Input
--- @field code agentic.UserConfig.Windows.Code
--- @field files agentic.UserConfig.Windows.Files
--- @field diagnostics agentic.UserConfig.Windows.Diagnostics
--- @field todos agentic.UserConfig.Windows.Todos

--- @class agentic.UserConfig.SpinnerChars
--- @field generating string[]
--- @field thinking string[]
--- @field searching string[]
--- @field busy string[]

--- Icons used to identify tool call states
--- @class agentic.UserConfig.StatusIcons
--- @field pending string
--- @field in_progress string
--- @field completed string
--- @field failed string

--- Icons used for diagnostics in the context panel
--- @class agentic.UserConfig.DiagnosticIcons
--- @field error string
--- @field warn string
--- @field info string
--- @field hint string

--- @class agentic.UserConfig.PermissionIcons
--- @field allow_once string
--- @field allow_always string
--- @field reject_once string
--- @field reject_always string

--- @class agentic.UserConfig.ChatIcons
--- @field user string
--- @field agent string

--- Icons used for message states in the chat widget
--- @class agentic.UserConfig.MessageIcons
--- @field thinking string
--- @field finished string
--- @field stopped string
--- @field error string

--- @class agentic.UserConfig.FilePicker
--- @field enabled boolean

--- @class agentic.UserConfig.ImagePaste
--- @field enabled boolean Enable image drag-and-drop to add images to referenced files

--- @class agentic.UserConfig.AutoScroll
--- @field threshold integer Lines from bottom to trigger auto-scroll (default: 10)

--- Show diff preview for edit tool calls in the buffer
--- @class agentic.UserConfig.DiffPreview
--- @field enabled boolean
--- @field layout "inline" | "split"
--- @field center_on_navigate_hunks boolean

--- Tool call folding configuration
--- @class agentic.UserConfig.Folding.ToolCalls
--- @field enabled boolean Whether to fold tool call bodies.
--- @field threshold integer Fold when interior exceeds this many lines. 0 always folds. Negative values are clamped to 0.

--- Folding behavior in the chat buffer
--- @class agentic.UserConfig.Folding
--- @field tool_calls agentic.UserConfig.Folding.ToolCalls

--- @class agentic.UserConfig.Hooks
--- @field on_create_session_response? fun(data: agentic.UserConfig.CreateSessionResponseData): nil
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil
--- @field on_session_update? fun(data: agentic.UserConfig.SessionUpdateData): nil
--- @field on_file_edit? fun(data: agentic.UserConfig.FileEditData): nil

--- Control various behaviors and features of the plugin
--- @class agentic.UserConfig.Settings
--- @field move_cursor_to_chat_on_submit boolean Automatically move cursor to chat window after submitting a prompt

--- Nested partial types for user config overrides
--- @class (partial) agentic.PartialUserConfig.Windows.Chat: agentic.UserConfig.Windows.Chat
--- @class (partial) agentic.PartialUserConfig.Windows.Input: agentic.UserConfig.Windows.Input
--- @class (partial) agentic.PartialUserConfig.Windows.Code: agentic.UserConfig.Windows.Code
--- @class (partial) agentic.PartialUserConfig.Windows.Files: agentic.UserConfig.Windows.Files
--- @class (partial) agentic.PartialUserConfig.Windows.Diagnostics: agentic.UserConfig.Windows.Diagnostics
--- @class (partial) agentic.PartialUserConfig.Windows.Todos: agentic.UserConfig.Windows.Todos
--- @class (partial) agentic.PartialUserConfig.Keymaps: agentic.UserConfig.Keymaps
--- @class (partial) agentic.PartialUserConfig.SpinnerChars: agentic.UserConfig.SpinnerChars
--- @class (partial) agentic.PartialUserConfig.StatusIcons: agentic.UserConfig.StatusIcons
--- @class (partial) agentic.PartialUserConfig.DiagnosticIcons: agentic.UserConfig.DiagnosticIcons
--- @class (partial) agentic.PartialUserConfig.PermissionIcons: agentic.UserConfig.PermissionIcons
--- @class (partial) agentic.PartialUserConfig.ChatIcons: agentic.UserConfig.ChatIcons
--- @class (partial) agentic.PartialUserConfig.MessageIcons: agentic.UserConfig.MessageIcons
--- @class (partial) agentic.PartialUserConfig.FilePicker: agentic.UserConfig.FilePicker
--- @class (partial) agentic.PartialUserConfig.ImagePaste: agentic.UserConfig.ImagePaste
--- @class (partial) agentic.PartialUserConfig.AutoScroll: agentic.UserConfig.AutoScroll
--- @class (partial) agentic.PartialUserConfig.DiffPreview: agentic.UserConfig.DiffPreview
--- @class (partial) agentic.PartialUserConfig.Folding.ToolCalls: agentic.UserConfig.Folding.ToolCalls
--- @class (partial) agentic.PartialUserConfig.Settings: agentic.UserConfig.Settings

--- Windows partial with nested type overrides
--- @class (partial) agentic.PartialUserConfig.Windows: agentic.UserConfig.Windows
--- @field chat? agentic.PartialUserConfig.Windows.Chat
--- @field input? agentic.PartialUserConfig.Windows.Input
--- @field code? agentic.PartialUserConfig.Windows.Code
--- @field files? agentic.PartialUserConfig.Windows.Files
--- @field diagnostics? agentic.PartialUserConfig.Windows.Diagnostics
--- @field todos? agentic.PartialUserConfig.Windows.Todos

--- Folding partial with nested type overrides
--- @class (partial) agentic.PartialUserConfig.Folding: agentic.UserConfig.Folding
--- @field tool_calls? agentic.PartialUserConfig.Folding.ToolCalls

--- Top-level partial config -- all UserConfig fields become optional
--- Nested fields override to use partial variants
--- @class (partial) agentic.PartialUserConfig: agentic.UserConfig
--- @field windows? agentic.PartialUserConfig.Windows
--- @field keymaps? agentic.PartialUserConfig.Keymaps
--- @field spinner_chars? agentic.PartialUserConfig.SpinnerChars
--- @field status_icons? agentic.PartialUserConfig.StatusIcons
--- @field diagnostic_icons? agentic.PartialUserConfig.DiagnosticIcons
--- @field permission_icons? agentic.PartialUserConfig.PermissionIcons
--- @field chat_icons? agentic.PartialUserConfig.ChatIcons
--- @field message_icons? agentic.PartialUserConfig.MessageIcons
--- @field file_picker? agentic.PartialUserConfig.FilePicker
--- @field image_paste? agentic.PartialUserConfig.ImagePaste
--- @field auto_scroll? agentic.PartialUserConfig.AutoScroll
--- @field diff_preview? agentic.PartialUserConfig.DiffPreview
--- @field folding? agentic.PartialUserConfig.Folding
--- @field settings? agentic.PartialUserConfig.Settings

--- @class agentic.UserConfig
--- @field debug boolean Enable printing debug messages which can be read via `:messages`
--- @field provider agentic.UserConfig.ProviderName
--- @field acp_providers table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
--- @field windows agentic.UserConfig.Windows
--- @field keymaps agentic.UserConfig.Keymaps
--- @field spinner_chars agentic.UserConfig.SpinnerChars
--- @field status_icons agentic.UserConfig.StatusIcons
--- @field diagnostic_icons agentic.UserConfig.DiagnosticIcons
--- @field permission_icons agentic.UserConfig.PermissionIcons
--- @field chat_icons agentic.UserConfig.ChatIcons
--- @field message_icons agentic.UserConfig.MessageIcons
--- @field file_picker agentic.UserConfig.FilePicker
--- @field image_paste agentic.UserConfig.ImagePaste
--- @field auto_scroll agentic.UserConfig.AutoScroll
--- @field diff_preview agentic.UserConfig.DiffPreview
--- @field folding agentic.UserConfig.Folding
--- @field hooks agentic.UserConfig.Hooks
--- @field headers agentic.UserConfig.Headers
--- @field settings agentic.UserConfig.Settings
local ConfigDefault = {
    debug = false,

    provider = "claude-agent-acp",

    acp_providers = {
        ["claude-agent-acp"] = {
            name = "Claude Agent ACP",
            command = "claude-agent-acp",
            env = {},
        },

        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            env = {},
        },

        ["gemini-acp"] = {
            name = "Gemini ACP",
            command = "gemini",
            args = { "--acp" },
            env = {},
        },

        ["codex-acp"] = {
            name = "Codex ACP",
            -- https://github.com/zed-industries/codex-acp/releases
            -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
            command = "codex-acp",
            args = {
                -- "-c",
                -- "features.web_search_request=true", -- disabled as it doesn't send proper tool call messages
            },
            env = {},
        },

        ["opencode-acp"] = {
            name = "OpenCode ACP",
            command = "opencode",
            args = { "acp" },
            env = {},
        },

        ["cursor-acp"] = {
            name = "Cursor Agent ACP",
            command = "cursor-agent",
            args = {
                "acp",
            },
            env = {},
        },

        ["copilot-acp"] = {
            name = "Copilot ACP",
            command = "copilot",
            args = {
                "--acp",
                "--stdio",
            },
            env = {},
        },

        ["auggie-acp"] = {
            name = "Auggie ACP",
            command = "auggie",
            args = {
                "--acp",
            },
            env = {},
        },

        ["mistral-vibe-acp"] = {
            name = "Mistral Vibe ACP",
            command = "vibe-acp",
            args = {},
            env = {},
        },

        ["cline-acp"] = {
            name = "Cline ACP",
            command = "cline",
            args = { "--acp" },
            env = {},
        },

        ["goose-acp"] = {
            name = "Goose ACP",
            command = "goose",
            args = { "acp" },
            env = {},
        },
    },

    windows = {
        position = "right",
        width = "40%",
        height = "30%",
        stack_width_ratio = 0.4,
        chat = { win_opts = {} },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = 10, win_opts = {} },
    },

    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            close = "q",
            change_mode = {
                {
                    "<S-Tab>",
                    mode = { "i", "n", "v" },
                },
            },
            switch_provider = "<localLeader>s",
            switch_model = "<localLeader>m",
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            submit = {
                "<CR>",
                {
                    "<C-s>",
                    mode = { "i", "n", "v" },
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
                },
            },

            accept_completion = {
                {
                    "<Tab>",
                    mode = { "i" },
                },
            },
        },

        --- Keys bindings for diff preview navigation
        diff_preview = {
            next_hunk = "]c",
            prev_hunk = "[c",
        },
    },

    -- stylua: ignore start
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
        busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
    },
    -- stylua: ignore end

    status_icons = {
        pending = "󰔛",
        in_progress = "󰔛",
        completed = "✔",
        failed = "",
    },

    diagnostic_icons = {
        error = "❌",
        warn = "⚠️",
        info = "ℹ️",
        hint = "✨",
    },

    permission_icons = {
        allow_once = "",
        allow_always = "",
        reject_once = "",
        reject_always = "󰜺",
    },

    chat_icons = {
        user = " ",
        agent = "󱚠 ",
    },

    message_icons = {
        thinking = "🧠",
        finished = "🏁",
        stopped = "🛑",
        error = "❌",
    },

    file_picker = {
        enabled = true,
    },

    image_paste = {
        enabled = true,
    },

    auto_scroll = {
        threshold = 10,
    },

    diff_preview = {
        enabled = true,
        layout = "split",
        center_on_navigate_hunks = true,
    },

    folding = {
        tool_calls = {
            enabled = true,
            threshold = 10,
        },
    },

    hooks = {
        on_create_session_response = nil,
        on_prompt_submit = nil,
        on_response_complete = nil,
        on_session_update = nil,
        on_file_edit = nil,
    },

    headers = {},

    settings = {
        move_cursor_to_chat_on_submit = true,
    },
}

return ConfigDefault
