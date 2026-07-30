local Logger = require("agentic.utils.logger")

--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|false result false when the buffer is invalid or the callback errors
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

--- `focusable` is checked alongside `hide` because a focusable hidden float
--- would otherwise win the lookup and absorb a winbar nobody can see.
--- @param winid integer
--- @param tabpage integer|nil
--- @return boolean
local function is_visible_win(winid, tabpage)
    local config = vim.api.nvim_win_get_config(winid)
    if not config.focusable or config.hide then
        return false
    end

    if tabpage == nil then
        return true
    end

    local ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
    return ok and win_tab == tabpage
end

--- Safe to act on: valid AND sitting in a live tabpage.
---
--- `nvim_win_is_valid` alone is not enough: on 0.11.x `tabclose` leaves handles that
--- answer valid but segfault in `nvim_win_close`, and post-tabclose background updates
--- reach exactly those. Use before any write on a handle held across an event boundary
--- (`nvim_win_close`, `nvim_win_call`, `nvim_win_set_config`); bare validity is fine for
--- reads and for deciding whether to open a new window.
--- @param winid integer|nil
--- @return boolean
function BufHelpers.is_win_usable(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return false
    end

    local ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
    return ok and vim.api.nvim_tabpage_is_valid(win_tab)
end

--- Use instead of `vim.fn.bufwinid`, which only deals with the current tabpage and returns the hidden chat float.
--- @param bufnr integer
--- @param preferred_winid integer|nil The owner's own window, preferred over any other match
--- @param tabpage integer|nil Restrict the search to this tabpage
--- @return integer|nil winid
function BufHelpers.find_visible_win(bufnr, preferred_winid, tabpage)
    if
        preferred_winid
        and vim.api.nvim_win_is_valid(preferred_winid)
        and vim.api.nvim_win_get_buf(preferred_winid) == bufnr
        and is_visible_win(preferred_winid, tabpage)
    then
        return preferred_winid
    end

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if is_visible_win(winid, tabpage) then
            return winid
        end
    end

    return nil
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

--- `nvim_win_set_width`/`_set_height` are deprecated for `nvim_win_resize`, which only exists on 0.13+.
--- @param winid integer
--- @param width integer -1 leaves the axis unchanged
--- @param height integer -1 leaves the axis unchanged
local function resize_win(winid, width, height)
    if vim.fn.has("nvim-0.13") == 1 then
        vim.api.nvim_win_resize(winid, width, height, {})
        return
    end

    --- @diagnostic disable: deprecated
    if width >= 0 then
        vim.api.nvim_win_set_width(winid, width)
    end
    if height >= 0 then
        vim.api.nvim_win_set_height(winid, height)
    end
    --- @diagnostic enable: deprecated
end

--- @param winid integer
--- @param width integer
function BufHelpers.win_set_width(winid, width)
    resize_win(winid, width, -1)
end

--- @param winid integer
--- @param height integer
function BufHelpers.win_set_height(winid, height)
    resize_win(winid, -1, height)
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
