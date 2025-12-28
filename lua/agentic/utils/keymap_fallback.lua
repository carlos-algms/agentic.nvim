--- Keymap fallback utility for handling existing key mappings
--- Provides functionality to detect and execute previous mappings for keys
--- while preventing infinite loops through marker-based identification
local M = {}

--- Unique marker to identify our own mappings and prevent infinite loops
M.MARKER = "[agentic-fallback]"

--- Checks if a mapping belongs to agentic (prevents infinite loops)
--- @param mapping table
--- @return boolean
local function is_agentic_mapping(mapping)
    return mapping.desc and mapping.desc:find(M.MARKER, 1, true) ~= nil
end

--- Gets existing mapping for a key using vim.fn.maparg
--- Automatically checks buffer-local first, then global
--- Skips mappings created by agentic to prevent infinite loops
--- @param mode string
--- @param lhs string
--- @return table|nil mapping dict or nil if no mapping
function M.get_existing_mapping(mode, lhs)
    local mapping = vim.fn.maparg(lhs, mode, false, true)

    -- maparg returns empty dict {} if no mapping found
    if vim.tbl_isempty(mapping) then
        return nil
    end

    -- Skip our own mappings to prevent infinite loops
    if is_agentic_mapping(mapping) then
        return nil
    end

    return mapping
end

--- Executes a fallback mapping for use in expr mappings
--- IMPORTANT: Always returns a string (never nil) for expr mapping compatibility
--- @param mapping table|nil The mapping dict from get_existing_mapping
--- @param default_key string The literal key to return if no mapping
--- @return string The keys to feed
function M.execute_fallback(mapping, default_key)
    if not mapping then
        return vim.api.nvim_replace_termcodes(default_key, true, true, true)
    end

    -- Handle Lua callback
    if type(mapping.callback) == "function" then
        if mapping.expr == 1 then
            -- Expr callback: call and return result
            local result = mapping.callback()
            if type(result) == "string" then
                if mapping.replace_keycodes == 1 then
                    result =
                        vim.api.nvim_replace_termcodes(result, true, true, true)
                end
                return result
            end
            -- Callback returned non-string, use default
            return vim.api.nvim_replace_termcodes(default_key, true, true, true)
        else
            -- Non-expr callback: schedule execution, return empty string
            -- We can't return nil from an expr mapping, so we schedule the
            -- callback and return "" to avoid inserting anything
            vim.schedule(mapping.callback)
            return ""
        end
    end

    -- Handle string RHS
    if mapping.rhs and mapping.rhs ~= "" then
        if mapping.expr == 1 then
            -- Expr mapping with string RHS: evaluate vimscript
            local ok, result = pcall(vim.api.nvim_eval, mapping.rhs)
            if ok and type(result) == "string" then
                return result
            end
            -- Eval failed, use default
            return vim.api.nvim_replace_termcodes(default_key, true, true, true)
        else
            -- Regular mapping: return the RHS directly
            return vim.api.nvim_replace_termcodes(mapping.rhs, true, true, true)
        end
    end

    return vim.api.nvim_replace_termcodes(default_key, true, true, true)
end

return M
