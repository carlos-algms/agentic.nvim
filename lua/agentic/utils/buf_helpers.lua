--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- Executes a callback function with the specified buffer set to modifiable.
--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|nil
function BufHelpers.with_modifiable(bufnr, callback)
    local original_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    local _ok, response = pcall(callback, bufnr)
    vim.api.nvim_set_option_value("modifiable", original_modifiable, { buf = bufnr })
    return response
end

function BufHelpers.start_insert_on_last_char()
    vim.cmd("normal! G$")
    vim.cmd("startinsert!")
end

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|nil
function BufHelpers.execute_on_buffer(bufnr, callback)
    return vim.api.nvim_buf_call(bufnr, function()
        return callback(bufnr)
    end)
end

return BufHelpers