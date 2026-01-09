--- Health check for agentic.nvim
--- This file is auto-discovered by :checkhealth
--- Users can run :checkhealth agentic to see only agentic.nvim health
local M = {}
local vim_health = vim.health

function M.check()
    local ACPHealth = require("agentic.acp.acp_health")
    local Config = require("agentic.config")

    vim_health.start("agentic.nvim")
    -- Check Neovim version
    local nvim_version = vim.version()
    local required_version = { 0, 11, 0 }
    if
        nvim_version.major > required_version[1]
        or (
            nvim_version.major == required_version[1]
            and nvim_version.minor >= required_version[2]
        )
    then
        vim_health.ok(
            string.format(
                "Neovim version %d.%d.%d",
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    else
        vim_health.error(
            string.format(
                "Neovim >= %d.%d.%d required (current: %d.%d.%d)",
                required_version[1],
                required_version[2],
                required_version[3],
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    end

    -- Check current provider
    vim_health.start("ACP Provider Configuration")
    local provider_name = Config.provider
    local provider_config = Config.acp_providers[provider_name]
    if not provider_config then
        vim_health.error(
            string.format(
                "Provider '%s' not found in config.acp_providers",
                provider_name
            )
        )
    else
        vim_health.ok(
            string.format(
                "Current provider: %s",
                provider_config.name or provider_name
            )
        )
        local command = provider_config.command
        if ACPHealth.is_command_available(command) then
            vim_health.ok(string.format("%s: installed", command))
        else
            vim_health.error(
                string.format(
                    "%s: not found in PATH or not executable",
                    command
                ),
                {
                    "See requirements: https://github.com/carlos-algms/agentic.nvim?tab=readme-ov-file#-requirements",
                }
            )
        end
    end

    -- Check all configured providers (excluding current one)
    vim_health.start(
        "Other ACP Providers (optional, if don't intend to use them)"
    )
    for name, config in pairs(Config.acp_providers) do
        if config and name ~= provider_name then
            local command = config.command
            if ACPHealth.is_command_available(command) then
                vim_health.ok(
                    string.format("[%s] %s: installed", name, command)
                )
            else
                vim_health.warn(
                    string.format("[%s] %s: not found", name, command)
                )
            end
        end
    end

    -- Check Node.js and package managers
    vim_health.start("Node.js and Package Managers")
    vim_health.info(
        "Most of the ACP providers require Node.js and a package manager to run, so you'll need at least one installed."
    )

    if ACPHealth.is_node_installed() then
        vim_health.ok("node: installed")
    else
        vim_health.error("node: not found")
    end

    local managers = { "pnpm", "bun", "yarn", "npm" }
    for _, name in ipairs(managers) do
        local check_fn = ACPHealth["is_" .. name .. "_installed"]
        if check_fn and check_fn() then
            if name == "npm" then
                vim_health.ok(
                    string.format(
                        "%s: installed (global path tied to node version, packages are lost when switching node versions)",
                        name
                    )
                )
            else
                vim_health.ok(string.format("%s: installed", name))
            end
        end
    end

    -- Check optional dependencies
    vim_health.start("Optional Dependencies")
    local Clipboard = require("agentic.ui.clipboard")
    if Clipboard.is_img_clip_installed() then
        vim_health.ok("hakonharnes/img-clip.nvim: installed")
    else
        vim_health.info(
            "hakonharnes/img-clip.nvim: not installed (optional - enables image pasting from clipboard)"
        )
    end
end

return M
