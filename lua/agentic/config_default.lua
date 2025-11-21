---@class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    ---@type "claude-acp" | "gemini-acp" | "codex-acp" | "opencode-acp"
    provider = "claude-acp",

    --- @class agentic.UserConfig.ACPProviders
    acp_providers = {
        ["claude-acp"] = {
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
            command = "gemini",
            args = { "--experimental-acp" },
            env = {
                NODE_NO_WARNINGS = "1",
                IS_AI_TERMINAL = "1",
            },
        },

        ["codex-acp"] = {
            -- https://github.com/zed-industries/codex-acp/releases
            -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
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

    --- @class agentic.UserConfig.Windows
    windows = {
        width = "40%",
        input = {
            height = 10,
        },
    },

    --- @class agentic.UserConfig.StatusIcons
    status_icons = {
        pending = "󰔛",
        completed = "✔",
        failed = "",
    },
}

return ConfigDefault
