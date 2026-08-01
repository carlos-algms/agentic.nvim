-- lua/agentic/ui/buffer_guard.lua
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- @class agentic.ui.BufferGuard
local BufferGuard = {}

--- @class agentic.ui.BufferGuard.Callbacks
--- @field tab_page_id integer

--- @param widget agentic.ui.ChatWidget
--- @return integer|nil destination
local function find_destination(widget)
    local tabpage = widget.tab_page_id
    if not vim.api.nvim_tabpage_is_valid(tabpage) then
        return nil
    end

    local destination = widget:find_first_non_widget_window()
        or widget:open_editor_window()
    if
        not destination
        or not BufHelpers.is_win_usable(destination)
        or vim.api.nvim_win_get_tabpage(destination) ~= tabpage
    then
        return nil
    end

    return destination
end

--- Redirect a foreign buffer out of a widget window.
--- The cursor follows the buffer to the target window via
--- vim.schedule — setting current_win inside BufEnter doesn't
--- stick because Neovim resets the window after the autocmd.
--- @param foreign_buf integer
--- @param widget agentic.ui.ChatWidget
--- @param owner_bufnr integer
local function redirect_foreign(foreign_buf, widget, owner_bufnr)
    if not vim.api.nvim_buf_is_valid(foreign_buf) then
        return
    end

    local target_win = find_destination(widget)
    if not target_win then
        Logger.debug("BufferGuard: no target window for redirect")
        return
    end

    pcall(vim.api.nvim_win_set_buf, target_win, foreign_buf)

    -- Move cursor to follow the redirected buffer. Deferred via
    -- vim.schedule because Neovim resets current_win after
    -- BufEnter autocmd handlers complete.
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(foreign_buf) then
            return
        end

        local live_widget = WidgetRegistry.get(owner_bufnr)
        if not live_widget or live_widget ~= widget then
            return
        end

        local destination = find_destination(live_widget)
        if not destination then
            return
        end

        pcall(vim.api.nvim_win_set_buf, destination, foreign_buf)
        pcall(vim.api.nvim_set_current_win, destination)
    end)
end

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
        redirect_foreign(cur_buf, widget, expected)
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

        transfer_ownership(widget, cur_buf, new_buf)
        vim.w[cur_win].agentic_bufnr = new_buf
        vim.api.nvim_win_set_buf(cur_win, new_buf)

        -- Redirect the (now-named) repurposed buffer to the editor
        redirect_foreign(cur_buf, widget, new_buf)
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
