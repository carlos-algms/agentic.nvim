--- @alias agentic.UserConfig.ProviderName "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp"

--- @class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    --- @type agentic.UserConfig.ProviderName
    provider = "claude-acp",

    --- @type table<agentic.UserConfig.ProviderName, agentic.acp.ProviderConfig>
    acp_providers = {
        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            -- command = "pnpm",
            -- args = {
            --     "dlx",
            --     "@zed-industries/claude-code-acp",
            -- },
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
                ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
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
            args = {},
            env = {
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
    },

    --- @class agentic.UserConfig.Windows
    windows = {
        width = "40%",
        input = {
            height = 10,
        },
    },

    --- @class agentic.UserConfig.SpinnerChars
    --- @field generating string[]
    --- @field thinking string[]
    --- @field searching string[]
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨", "😐" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
    },

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
}

return ConfigDefault
