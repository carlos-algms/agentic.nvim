local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.DiffState
--- @field preview_bufnr? integer
--- @field preview_winid? integer
--- @field split_state? table<string, agentic.ui.DiffSplitView.State>

--- Coordinates edit-diff previews for one session.
--- @class agentic.ui.DiffCoordinator
--- @field _widget agentic.ui.ChatWidget
--- @field _message_writer agentic.ui.MessageWriter
--- @field _get_tab_page_id fun(): integer|nil
--- @field diff_state agentic.ui.DiffState
local DiffCoordinator = {}
DiffCoordinator.__index = DiffCoordinator

--- @param widget agentic.ui.ChatWidget
--- @param message_writer agentic.ui.MessageWriter
--- @param get_tab_page_id fun(): integer|nil Resolves the session's tabpage live
--- @return agentic.ui.DiffCoordinator
function DiffCoordinator:new(widget, message_writer, get_tab_page_id)
    --- @type agentic.ui.DiffState
    local diff_state = {}
    local instance = setmetatable({
        _widget = widget,
        _message_writer = message_writer,
        _get_tab_page_id = get_tab_page_id,
        diff_state = diff_state,
    }, self)

    DiffPreview.setup_diff_navigation_keymaps(widget.buf_nrs, diff_state)
    return instance
end

--- Resolve the tracker for an edit tool call that carries a renderable diff.
--- @param tool_call_id string|nil
--- @return agentic.ui.MessageWriter.ToolCallBlock|nil tracker
function DiffCoordinator:_edit_tracker(tool_call_id)
    local tracker = tool_call_id
        and self._message_writer.tool_call_blocks[tool_call_id]

    if
        not tracker
        or tracker.kind ~= "edit"
        or tracker.diff == nil
        or not tracker.file_path
    then
        return nil
    end

    return tracker
end

--- @param tool_call_id string
function DiffCoordinator:show(tool_call_id)
    local tabpage = self._get_tab_page_id()
    -- Only show diff if enabled by user config,
    -- and cursor is in the same tabpage as this session to avoid disruption
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= tabpage
    then
        return
    end

    local tracker = self:_edit_tracker(tool_call_id)
    if not tracker then
        return
    end

    DiffPreview.show_diff({
        file_path = tracker.file_path,
        diff = tracker.diff,
        state = self.diff_state,
        tabpage = tabpage,
        get_winid = function(bufnr)
            local winid = self._widget:find_first_non_widget_window()
            if not winid then
                return self._widget:open_editor_window(bufnr)
            end
            local ok, err = pcall(vim.api.nvim_win_set_buf, winid, bufnr)

            if not ok then
                Logger.notify(
                    "Failed to set buffer in window: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return nil
            end
            return winid
        end,
    })
end

--- @param tool_call_id string
--- @param is_rejection boolean|nil
function DiffCoordinator:clear(tool_call_id, is_rejection)
    local tracker = self:_edit_tracker(tool_call_id)
    if not tracker then
        return
    end

    DiffPreview.clear_diff(tracker.file_path, is_rejection, self.diff_state)
end

return DiffCoordinator
