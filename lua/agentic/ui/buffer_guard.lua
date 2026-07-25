-- lua/agentic/ui/buffer_guard.lua
local Logger = require("agentic.utils.logger")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- @class agentic.ui.BufferGuard
local BufferGuard = {}

--- Redirect a foreign buffer out of a widget window.
--- The cursor follows the buffer to the target window via
--- vim.schedule — setting current_win inside BufEnter doesn't
--- stick because Neovim resets the window after the autocmd.
--- @param foreign_buf integer
--- @param widget agentic.ui.ChatWidget Owner of the window being cleared
local function redirect_foreign(foreign_buf, widget)
    if not vim.api.nvim_buf_is_valid(foreign_buf) then
        return
    end

    -- The OWNING widget resolves the target: with one shared augroup, using any
    -- other widget would eject the buffer into a different session's tab.
    local target_win = widget:find_first_non_widget_window()
        or widget:open_editor_window()

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

--- Hands the replacement scratch buffer to the widget that owned the buffer it
--- replaces, so `WidgetRegistry` and `buf_nrs` never disagree.
--- Without this, `agentic_bufnr` would name a buffer no widget owns and the next
--- BufEnter in that window could not resolve an owner at all.
--- @param widget agentic.ui.ChatWidget
--- @param old_bufnr integer
--- @param new_bufnr integer
local function transfer_ownership(widget, old_bufnr, new_bufnr)
    for panel, bufnr in pairs(widget.buf_nrs) do
        if bufnr == old_bufnr then
            widget.buf_nrs[panel] = new_bufnr
        end
    end

    WidgetRegistry.register(widget)
end

--- Core handler: called on BufEnter for every buffer.
--- If a non-widget buffer lands in a widget window, redirect it.
local function on_buf_enter()
    local cur_win = vim.api.nvim_get_current_win()

    -- Check if this window has an expected widget buffer
    -- (set via vim.w[winid].agentic_bufnr at window creation)
    local expected = vim.w[cur_win].agentic_bufnr
    if not expected then
        -- Not a widget window → nothing to do
        return
    end

    -- One augroup serves every widget, so the owner is resolved per event
    -- instead of captured per attachment. No owner means the widget was
    -- destroyed and its window is being torn down.
    local widget = WidgetRegistry.get(expected)
    if not widget then
        return
    end

    local cur_buf = vim.api.nvim_get_current_buf()

    if cur_buf ~= expected then
        if not vim.api.nvim_buf_is_valid(expected) then
            return
        end
        pcall(vim.api.nvim_win_set_buf, cur_win, expected)
        redirect_foreign(cur_buf, widget)
        return
    end

    -- Same buffer ID, but check if the widget buffer was repurposed:
    -- A regular (non-nofile) widget buffer can have a file loaded into
    -- it via :edit (same buffer ID, now with a file path).
    -- nofile buffers are exempt: they legitimately hold display names
    -- set via nvim_buf_set_name (e.g. "󰦨 Prompt") without being
    -- repurposed.
    local buf_name = vim.api.nvim_buf_get_name(cur_buf)
    local buftype = vim.bo[cur_buf].buftype
    if buf_name ~= "" and buftype ~= "nofile" then
        -- Widget buffer was repurposed with a file. Create a fresh
        -- scratch buffer to keep the widget window intact.
        local new_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[new_buf].buftype = "nofile"

        -- Ownership and the window marker both move before the buffer does:
        -- `nvim_win_set_buf` on the current window fires BufEnter again, and
        -- that reentrant pass must already see the replacement as expected.
        transfer_ownership(widget, cur_buf, new_buf)
        vim.w[cur_win].agentic_bufnr = new_buf
        vim.api.nvim_win_set_buf(cur_win, new_buf)

        -- Redirect the (now-named) repurposed buffer to the editor
        redirect_foreign(cur_buf, widget)
    end
end

--- Id of the single module-wide augroup, nil until the first `ensure`.
--- Module-level state is correct here: augroup ids are global, and isolation
--- comes from the per-window `vim.w[winid].agentic_bufnr` marker the handler
--- reads, not from one augroup per widget.
--- @type integer|nil
local augroup = nil

--- Creates the shared BufEnter guard once. Later calls are no-ops.
function BufferGuard.ensure()
    if augroup then
        return
    end

    augroup =
        vim.api.nvim_create_augroup("AgenticBufferGuard", { clear = true })

    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        callback = on_buf_enter,
        desc = "Agentic: redirect non-widget buffers out of widget windows",
    })
end

return BufferGuard
