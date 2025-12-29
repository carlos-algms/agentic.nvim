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

--- Gets existing mapping for a key
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

    -- Skip our own mappings and search global scope
    if is_agentic_mapping(mapping) then
        -- Our buffer-local mapping was found, now check global mappings
        local global_maps = vim.api.nvim_get_keymap(mode)
        for _, map in ipairs(global_maps) do
            if map.lhs == lhs and not is_agentic_mapping(map) then
                return map
            end
        end
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
            -- Example: copilot.vim's Tab mapping:
            --   i  <Tab>  & empty(get(g:, 'copilot_no_tab_map')) ? copilot#Accept() : "\t"
            -- The expression is evaluated and returns either copilot's result or "\t"
            local ok, result = pcall(vim.api.nvim_eval, mapping.rhs)
            if ok and type(result) == "string" then
                -- nvim_eval returns strings already in internal format (K_SPECIAL bytes).
                -- Do NOT call nvim_replace_termcodes here - it corrupts K_SPECIAL sequences.
                -- Our mapping must use replace_keycodes=false to prevent double-processing.
                return result
            end
            -- Eval failed (syntax error, undefined var) or returned non-string, use default
            return vim.api.nvim_replace_termcodes(default_key, true, true, true)
        else
            -- Regular mapping: return the RHS directly
            return vim.api.nvim_replace_termcodes(mapping.rhs, true, true, true)
        end
    end

    return vim.api.nvim_replace_termcodes(default_key, true, true, true)
end

return M
