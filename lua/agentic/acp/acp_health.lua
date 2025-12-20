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

return ACPHealth
