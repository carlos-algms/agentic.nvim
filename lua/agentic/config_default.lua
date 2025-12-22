--- @alias agentic.UserConfig.ProviderName "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp" | "cursor-acp"

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

--- @class agentic.UserConfig.Hooks
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>

--- @class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    --- @type agentic.UserConfig.ProviderName
    provider = "claude-acp",

    --- @type table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
    acp_providers = {
        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
        },

        ["gemini-acp"] = {
            name = "Gemini ACP",
            command = "gemini",
            args = { "--experimental-acp" },
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
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
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
        },

        ["opencode-acp"] = {
            name = "OpenCode ACP",
            command = "opencode",
            args = { "acp" },
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
        },

        ["cursor-acp"] = {
            name = "Cursor Agent ACP",
            command = "cursor-agent-acp",
            args = {},
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
        },
    },

    --- @class agentic.UserConfig.Windows
    windows = {
        width = "40%",
        input = {
            height = 10,
        },
    },

    --- Custom actions to be used with keymaps
    --- @class agentic.UserConfig.Actions
    actions = {},

    --- @type agentic.UserConfig.Keymaps
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
        },
    },

    -- stylua: ignore start
    --- @class agentic.UserConfig.SpinnerChars
    --- @field generating string[]
    --- @field thinking string[]
    --- @field searching string[]
    --- @field busy string[]
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
        busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
    },
    -- stylua: ignore end

    --- Icons used to identify tool call states
    --- @class agentic.UserConfig.StatusIcons
    status_icons = {
        pending = "󰔛",
        completed = "✔",
        failed = "",
    },

    --- @class agentic.UserConfig.PermissionIcons
    permission_icons = {
        allow_once = "",
        allow_always = "",
        reject_once = "",
        reject_always = "󰜺",
    },

    --- @class agentic.UserConfig.FilePicker
    file_picker = {
        enabled = true,
    },

    --- @type agentic.UserConfig.Hooks
    hooks = {
        on_prompt_submit = nil,
        on_response_complete = nil,
    },
}

return ConfigDefault
