local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")

--- Mutated in place by the stateless `DiffPreview` / `DiffSplitView` /
--- `HunkNavigation` modules, which receive it as an argument.
--- @class agentic.ui.DiffState
--- @field preview_bufnr? integer
--- @field preview_winid? integer Window the diff was painted in
--- @field split_state? table<string, agentic.ui.DiffSplitView.State> Keyed by absolute path: one slot per DiffState let a second pending edit to a DIFFERENT file overwrite the first, orphaning its scratch buffer and window

--- @class agentic.ui.DiffCoordinator
--- @field _widget agentic.ui.ChatWidget
--- @field _message_writer agentic.ui.MessageWriter
--- @field diff_state agentic.ui.DiffState
local DiffCoordinator = {}
DiffCoordinator.__index = DiffCoordinator

--- @param widget agentic.ui.ChatWidget
--- @param message_writer agentic.ui.MessageWriter
--- @return agentic.ui.DiffCoordinator
function DiffCoordinator:new(widget, message_writer)
    --- @type agentic.ui.DiffState
    local diff_state = {}

    local instance = setmetatable({
        _widget = widget,
        _message_writer = message_writer,
        diff_state = diff_state,
    }, self)

    -- Not in `ChatWidget:_bind_keymaps`: the closures need this diff state.
    DiffPreview.setup_diff_navigation_keymaps(widget.buf_nrs, diff_state)

    return instance
end

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
    -- Visible SOMEWHERE, not visible here: a background session renders into its own tab.
    local tabpage = self._widget:get_visible_tab_id()
    if not Config.diff_preview.enabled or not tabpage then
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
