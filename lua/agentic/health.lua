--- Health check for agentic.nvim
--- This file is auto-discovered by :checkhealth
--- Users can run :checkhealth agentic to see only agentic.nvim health
--- @class agentic.Health
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

    -- Clipboard image paste tooling
    vim_health.start("Clipboard Image Paste")
    local ClipboardImage = require("agentic.ui.clipboard_image")
    local platform = ClipboardImage.get_platform()
    local supported = ClipboardImage.is_supported()

    if platform == "mac" then
        vim_health.ok("Clipboard image paste: supported (no extra deps)")
    elseif platform == "win" then
        if supported then
            vim_health.ok("Clipboard image paste: supported (no extra deps)")
        else
            vim_health.warn(
                "Clipboard image paste: powershell.exe not found in PATH"
            )
        end
    elseif platform == "wsl" then
        if supported then
            vim_health.ok(
                "Clipboard image paste: supported through Windows interop"
            )
        else
            local has_powershell = vim.fn.executable("powershell.exe") == 1
            local has_wslpath = vim.fn.executable("wslpath") == 1
            if not has_powershell and not has_wslpath then
                vim_health.warn(
                    "Clipboard image paste: PowerShell interop (powershell.exe) and wslpath not found"
                )
            elseif not has_powershell then
                vim_health.warn(
                    "Clipboard image paste: PowerShell interop (powershell.exe) not found"
                )
            else
                vim_health.warn("Clipboard image paste: wslpath not found")
            end
        end
    elseif platform == "linux_wayland" then
        if supported then
            vim_health.ok("Clipboard image paste: wl-paste found")
        else
            vim_health.warn(
                "Clipboard image paste: wl-paste not found - install wl-clipboard"
            )
        end
    elseif platform == "linux_x11" then
        if supported then
            vim_health.ok(
                "Clipboard image paste: xclip found (clipboard access depends on session)"
            )
        else
            vim_health.warn(
                "Clipboard image paste: xclip not found - install xclip"
            )
        end
    else
        vim_health.warn("Clipboard image paste: platform not detected")
    end
end

return M
