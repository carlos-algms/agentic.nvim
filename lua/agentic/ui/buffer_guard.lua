-- lua/agentic/ui/buffer_guard.lua
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.BufferGuard
local BufferGuard = {}

--- @class agentic.ui.BufferGuard.Callbacks
--- @field tab_page_id integer
--- @field find_target_window fun(): integer|nil

--- Redirect a foreign buffer out of a widget window.
--- The cursor follows the buffer to the target window via
--- vim.schedule — setting current_win inside BufEnter doesn't
--- stick because Neovim resets the window after the autocmd.
--- @param foreign_buf integer
--- @param find_target_window fun(): integer|nil
local function redirect_foreign(foreign_buf, find_target_window)
    if not vim.api.nvim_buf_is_valid(foreign_buf) then
        return
    end

    local target_win = find_target_window()
    if not target_win then
        Logger.debug("BufferGuard: no target window for redirect")
        return
    end

    pcall(vim.api.nvim_win_set_buf, target_win, foreign_buf)

    -- Move cursor to follow the redirected buffer. Deferred via
    -- vim.schedule because Neovim resets current_win after
    -- BufEnter autocmd handlers complete.
    vim.schedule(function()
        if vim.api.nvim_win_is_valid(target_win) then
            pcall(vim.api.nvim_set_current_win, target_win)
        end
    end)
end

--- Core handler: called on BufEnter for every buffer.
--- If a non-widget buffer lands in a widget window, redirect it.
--- @param cb agentic.ui.BufferGuard.Callbacks
local function on_buf_enter(cb)
    -- Only handle events on this widget's tabpage
    if vim.api.nvim_get_current_tabpage() ~= cb.tab_page_id then
        return
    end

    local cur_win = vim.api.nvim_get_current_win()

    -- Check if this window has an expected widget buffer
    -- (set via vim.w[winid].agentic_bufnr at window creation)
    local expected = vim.w[cur_win].agentic_bufnr
    if not expected then
        -- Not a widget window → nothing to do
        return
    end

    local cur_buf = vim.api.nvim_get_current_buf()

    if cur_buf ~= expected then
        if not vim.api.nvim_buf_is_valid(expected) then
            return
        end
        pcall(vim.api.nvim_win_set_buf, cur_win, expected)
        redirect_foreign(cur_buf, cb.find_target_window)
        return
    end

    -- Same buffer ID, but check if the widget buffer was repurposed:
    -- A regular (non-nofile) widget buffer can have a file loaded into
    -- it via :edit (same buffer ID, now with a file path).
    -- nofile buffers are exempt: they legitimately hold display names
    -- set via nvim_buf_set_name (e.g. "󰦨 Prompt") without being
    -- repurposed. Window-local options (wrap, number, cursorline, etc.)
    -- belong to the window, not the buffer — verified via
    -- :h local-options and headless testing. A buffer briefly
    -- displayed in a widget window does NOT carry widget
    -- window options when moved to another window. So we
    -- simply move the buffer as-is.
    local buf_name = vim.api.nvim_buf_get_name(cur_buf)
    local buftype = vim.bo[cur_buf].buftype
    if buf_name ~= "" and buftype ~= "nofile" then
        -- Widget buffer was repurposed with a file. Create a fresh
        -- scratch buffer to keep the widget window intact.
        local new_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[new_buf].buftype = "nofile"
        vim.api.nvim_win_set_buf(cur_win, new_buf)
        vim.w[cur_win].agentic_bufnr = new_buf
        -- Redirect the (now-named) repurposed buffer to the editor
        redirect_foreign(cur_buf, cb.find_target_window)
    end
end

--- Attach buffer guard using callback functions.
--- @param callbacks agentic.ui.BufferGuard.Callbacks
--- @return integer augroup_id Used to detach later
function BufferGuard.attach(callbacks)
    local augroup = vim.api.nvim_create_augroup(
        "AgenticBufferGuard_" .. tostring(callbacks.tab_page_id),
        { clear = true }
    )

    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        callback = function()
            on_buf_enter(callbacks)
        end,
        desc = "Agentic: redirect non-widget buffers out of "
            .. "widget windows",
    })

    return augroup
end

--- Detach and clean up a buffer guard.
--- @param augroup_id integer
function BufferGuard.detach(augroup_id)
    pcall(vim.api.nvim_del_augroup_by_id, augroup_id)
end

return BufferGuard
