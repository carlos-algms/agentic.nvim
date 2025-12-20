--- Health check utilities for ACP providers and dependencies
--- @class agentic.acp.ACPHealth
local ACPHealth = {}

--- Check if a command exists and is executable
--- Handles command names (e.g., "node"), absolute paths (e.g., "/usr/bin/node"),
--- and tilde paths (e.g., "~/.local/bin/node")
--- @param command? string The command name or path to check
--- @return boolean exists Whether the command exists and is executable
function ACPHealth.is_command_available(command)
    if not command or command == "" then
        return false
    end
    local expanded = vim.fn.expand(command)
    return vim.fn.executable(expanded) == 1
end

--- Check if Node.js is installed and executable
--- @return boolean available
function ACPHealth.is_node_installed()
    return ACPHealth.is_command_available("node")
end

--- Check if npm is installed and executable
--- @return boolean available
function ACPHealth.is_npm_installed()
    return ACPHealth.is_command_available("npm")
end

--- Check if pnpm is installed and executable
--- @return boolean available
function ACPHealth.is_pnpm_installed()
    return ACPHealth.is_command_available("pnpm")
end

--- Check if yarn is installed and executable
--- @return boolean available
function ACPHealth.is_yarn_installed()
    return ACPHealth.is_command_available("yarn")
end

--- Check if bun is installed and executable
--- @return boolean available
function ACPHealth.is_bun_installed()
    return ACPHealth.is_command_available("bun")
end

--- Check if any Node.js package manager is available
--- Ordered by stability: version-independent global paths first
--- @return boolean available
--- @return string|nil manager_name Name of available package manager
function ACPHealth.get_available_package_manager()
    local managers = {
        { name = "pnpm", check = ACPHealth.is_pnpm_installed },
        { name = "bun", check = ACPHealth.is_bun_installed },
        { name = "yarn", check = ACPHealth.is_yarn_installed },
        { name = "npm", check = ACPHealth.is_npm_installed },
    }

    for _, manager in ipairs(managers) do
        if manager.check() then
            return true, manager.name
        end
    end

    return false, nil
end

--- Check if the configured ACP provider is available
--- Shows a warning window if not available
--- @return boolean available
function ACPHealth.check_configured_provider()
    local Config = require("agentic.config")
    local provider_name = Config.provider
    local provider_config = Config.acp_providers[provider_name]

    --- Markdown formatted lines to be shown in the warning window
    local lines = {}

    if not provider_config then
        vim.list_extend(lines, {
            string.format(
                "‼️ Provider **%s** not found in configuration.",
                provider_name
            ),
            "",
            "- If it's the first time you're using Agentic.nvim, you might have **NEVER** installed it",
            "",
            "- Have you switched your **Node.js version**? Globally installed packages are lost when switching versions with tools like nvm, fnm, etc...(out of this plugin's control)",
            "",
            "- It could be a typo 🤷",
            "",
        })
    elseif not ACPHealth.is_command_available(provider_config.command) then
        vim.list_extend(lines, {
            string.format(
                "‼️ **%s** (command: `%s`) is not installed or not executable.",
                provider_config.name or provider_name,
                provider_config.command or "unknown"
            ),
            "",
        })
    else
        return true
    end

    -- Build list of all available providers with installation status
    local available_providers = {}
    for key, _ in pairs(Config.acp_providers) do
        table.insert(available_providers, key)
    end
    table.sort(available_providers)

    table.insert(
        lines,
        "Supported providers: (You must have the one you want to use installed!)"
    )

    for _, provider in ipairs(available_providers) do
        local provider_cfg = Config.acp_providers[provider]
        local is_installed = false

        if provider_cfg and provider_cfg.command then
            is_installed = ACPHealth.is_command_available(provider_cfg.command)
        end

        local status = is_installed and "(✅ installed)"
            or "(❌ not installed)"

        table.insert(lines, string.format("- `%s` %s", provider, status))
    end

    vim.list_extend(lines, {
        "",
        "Check the `Requirements` section in the README for installation instructions:",
        "",
        "https://github.com/carlos-algms/agentic.nvim?tab=readme-ov-file#-requirements",
        "",
        "**PLEASE NOTE**: Agentic.nvim does NOT install any ACP providers on your behalf, for security and privacy reasons.",
        "",
        "Run `:checkhealth agentic` for more information.",
    })

    -- Build final message with header, error content, and footer
    local merged_lines = {
        "# Welcome to Agentic.nvim!",
        "",
        "🚨 **There're issues with your configuration or missing dependencies.** 🚨",
        "",
    }
    vim.list_extend(merged_lines, lines)

    ACPHealth._show_provider_warning(merged_lines)
    return false
end

--- Show a floating window with provider warning
--- @param lines string[]
function ACPHealth._show_provider_warning(lines)
    local width = math.floor(vim.o.columns * 0.5)
    local height = #lines + 3
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].syntax = "markdown"
    pcall(vim.treesitter.start, buf, "markdown")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Agentic.nvim - Warning ",
        title_pos = "center",
        footer = " q or <Esc> to close ",
        footer_pos = "right",
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true

    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "q",
        "<cmd>close<cr>",
        { noremap = true, silent = true }
    )
    vim.api.nvim_buf_set_keymap(
        buf,
        "n",
        "<Esc>",
        "<cmd>close<cr>",
        { noremap = true, silent = true }
    )

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_win_close(win, true)
                end
            end)
        end,
    })
end

return ACPHealth
