local Logger = require("agentic.utils.logger")

--- @class agentic.States
local M = {}

--- Safely set a state value, because the buffer/tab/window may not exist anymore
--- @param accessor table vim.b, vim.g, vim.w, or vim.t
--- @param id integer|string The buffer number, tabpage number, or other identifier
--- @param key string The key to set
--- @param value string|number|boolean|table Only raw lua values, no functions or userdata
--- @return nil
local function safe_set(accessor, id, key, value)
    local ok, err = pcall(function()
        accessor[id][key] = value
    end)

    if not ok then
        Logger.debug(
            "Failed to set state for id:",
            tostring(id),
            "key:",
            key,
            "error:",
            err
        )
    end
end

--- Safely get a state value, because the buffer/tab/window may not exist anymore
--- @param accessor table vim.b, vim.g, vim.w, or vim.t
--- @param id integer|string The buffer number, tabpage number, or other identifier
--- @param key string The key to get
--- @return any
local function safe_get(accessor, id, key)
    local ok, result = pcall(function()
        return accessor[id][key]
    end)

    if not ok then
        Logger.debug(
            "Failed to get state for id:",
            tostring(id),
            "key:",
            key,
            "error:",
            result
        )
        return nil
    end

    return result
end

--- Slash commands are stored per buffer, as it can only be triggered in insert mode, so the use will be in the right buffer
--- @param bufnr integer
--- @param items agentic.acp.CompletionItem[]
function M.setSlashCommands(bufnr, items)
    safe_set(vim.b, bufnr, "agentic_slash_commands", items)
end

--- Retrieve slash commands for the current buffer, we assume it's the correct one
--- as it can only be triggered in insert mode
--- @return agentic.acp.CompletionItem[]
function M.getSlashCommands()
    return safe_get(vim.b, 0, "agentic_slash_commands") or {}
end

return M
