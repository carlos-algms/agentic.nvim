-- lua/agentic/ui/buffer_guard.lua
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- @class agentic.ui.BufferGuard
local BufferGuard = {}

--- @param widget agentic.ui.ChatWidget
--- @return integer|nil destination
local function find_destination(widget)
    local tabpage = widget:get_visible_tab_id()
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return nil
    end

    local destination = widget:find_first_non_widget_window(tabpage)
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

    -- Neovim resets current_win after BufEnter handlers, so an inline set does not stick.
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

local function on_buf_enter()
    local cur_win = vim.api.nvim_get_current_win()

    -- Set by the layout at window creation; absent on every non-widget window.
    local expected = vim.w[cur_win].agentic_bufnr
    if not expected then
        return
    end

    -- Resolved per event, not per attachment: one augroup serves every widget.
    local widget = WidgetRegistry.get(expected)
    if not widget then
        return
    end

    local widget_tab = widget:get_visible_tab_id()
    if widget_tab ~= vim.api.nvim_get_current_tabpage() then
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

    -- `:edit` loads a file into a widget buffer, keeping the ID and gaining a
    -- path. `nofile` buffers legitimately carry display names (e.g. "󰦨 Prompt").
    local buf_name = vim.api.nvim_buf_get_name(cur_buf)
    local buftype = vim.bo[cur_buf].buftype
    if buf_name ~= "" and buftype ~= "nofile" then
        local new_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[new_buf].buftype = "nofile"

        -- Reentrant BufEnter must resolve the replacement before the buffer swap.
        transfer_ownership(widget, cur_buf, new_buf)
        vim.w[cur_win].agentic_bufnr = new_buf
        vim.api.nvim_win_set_buf(cur_win, new_buf)

        redirect_foreign(cur_buf, widget, new_buf)
    end
end

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
