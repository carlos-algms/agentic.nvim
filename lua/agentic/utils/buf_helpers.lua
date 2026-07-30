local Logger = require("agentic.utils.logger")

--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|false result the callback's own result, returned unchanged, or `false`
--- when the buffer is invalid or the callback errors. A callback that itself
--- returns `false` is therefore indistinguishable from those two failures.
function BufHelpers.with_modifiable(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local original_modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    local ok, response = pcall(callback, bufnr)

    vim.bo[bufnr].modifiable = original_modifiable

    if not ok then
        Logger.notify(
            "Error in with_modifiable: \n" .. tostring(response),
            vim.log.levels.ERROR,
            { title = "🐞 Error with modifiable callback" }
        )
        return false
    end

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
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    return vim.api.nvim_buf_call(bufnr, function()
        return callback(bufnr)
    end)
end

--- `buffer` was renamed to `buf` in neovim#38360 (0.12.0 final, `buffer` removed
--- in 0.15). Gated on 0.12.1 so 0.12.0-dev nightlies built before the rename —
--- which answer `has("nvim-0.12") == 1` but reject `buf` — still work.
--- @param opts table
--- @param bufnr integer
local function set_buffer_opt(opts, bufnr)
    --- @diagnostic disable: inject-field
    if vim.fn.has("nvim-0.12.1") == 1 then
        opts.buf = bufnr
    else
        opts.buffer = bufnr
    end
    --- @diagnostic enable: inject-field
end

--- Sets a keymap for a specific buffer.
--- @param bufnr integer
--- @param mode string|string[]
--- @param lhs string
--- @param rhs string|fun():any
--- @param opts vim.keymap.set.Opts|nil
function BufHelpers.keymap_set(bufnr, mode, lhs, rhs, opts)
    opts = opts or {}
    set_buffer_opt(opts, bufnr)
    vim.keymap.set(mode, lhs, rhs, opts)
end

--- Deletes a keymap for a specific buffer.
--- @param bufnr integer
--- @param mode string|string[]
--- @param lhs string
function BufHelpers.keymap_del(bufnr, mode, lhs)
    --- @type table
    local opts = {}
    set_buffer_opt(opts, bufnr)
    pcall(vim.keymap.del, mode, lhs, opts)
end

--- Normalizes a KeymapValue (string, string[], or array of string/KeymapEntry)
--- into `(modes, lhs)` pairs.
--- @param keymaps agentic.UserConfig.KeymapValue
--- @param fn fun(modes: string|string[], lhs: string)
local function each_keymap(keymaps, fn)
    if type(keymaps) == "string" then
        keymaps = { keymaps }
    end

    for _, key in ipairs(keymaps) do
        if type(key) == "table" and key.mode then
            fn(key.mode, key[1])
        else
            fn("n", key --[[@as string]])
        end
    end
end

--- @param keymaps agentic.UserConfig.KeymapValue
--- @param bufnr integer
--- @param callback fun():any
--- @param opts vim.keymap.set.Opts|nil
function BufHelpers.multi_keymap_set(keymaps, bufnr, callback, opts)
    each_keymap(keymaps, function(modes, lhs)
        BufHelpers.keymap_set(bufnr, modes, lhs, callback, opts)
    end)
end

--- @param keymaps agentic.UserConfig.KeymapValue
--- @param bufnr integer
function BufHelpers.multi_keymap_del(keymaps, bufnr)
    each_keymap(keymaps, function(modes, lhs)
        BufHelpers.keymap_del(bufnr, modes, lhs)
    end)
end

--- @param bufnr integer
--- @return boolean
function BufHelpers.is_buffer_empty(bufnr)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

function BufHelpers.feed_ESC_key()
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "nx",
        false
    )
end

return BufHelpers
