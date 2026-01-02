--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local DiffPreview = {}
DiffPreview.__index = DiffPreview

--- @type table<number, table>
local ref_by_buffer = setmetatable({}, { __mode = "v" })

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff { new: string[], old: string[], all?: boolean }
--- @field widget_windows table<string, number|nil> The chat widget sidebar windows - These are considered locked and we should find other windows to display the diff in

--- Finds the first window on the current tabpage that is NOT part of the chat widget
--- @param widget_windows table<string, number|nil> The chat widget window IDs to exclude
--- @return number|nil winid The first non-widget window ID, or nil if none found
local function find_first_non_widget_window(widget_windows)
    local current_tabpage = vim.api.nvim_get_current_tabpage()
    local all_windows = vim.api.nvim_tabpage_list_wins(current_tabpage)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(widget_windows) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            return winid
        end
    end

    return nil
end

--- Opens a new window on the left side with full height
--- @param bufnr number The buffer to display in the new window
--- @return number winid The newly created window ID
local function open_left_window(bufnr)
    local winid = vim.api.nvim_open_win(bufnr, true, {
        split = "left",
        win = -1,
    })
    return winid
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
function DiffPreview.show_diff(opts)
    local bufnr = vim.fn.bufnr(opts.file_path)

    if bufnr == -1 then
        return
    end

    local target_winid = find_first_non_widget_window(opts.widget_windows)

    if not target_winid then
        target_winid = open_left_window(bufnr)
    end
end

--- @param bufnr number
function DiffPreview.remove_diff(bufnr) end

return DiffPreview
