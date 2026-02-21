local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")

--- @class agentic.ui.TodoList
--- @field _bufnr integer
--- @field _on_change fun(todoList: agentic.ui.TodoList)
--- @field _on_close fun()
--- @field completed_count integer
--- @field total_count integer
local TodoList = {}
TodoList.__index = TodoList

--- @param bufnr integer
--- @param on_change fun(todoList: agentic.ui.TodoList)
--- @param on_close fun()
--- @return agentic.ui.TodoList
function TodoList:new(bufnr, on_change, on_close)
    return setmetatable({
        _bufnr = bufnr,
        _on_change = on_change,
        _on_close = on_close,
        completed_count = 0,
        total_count = 0,
    }, self)
end

--- @return boolean
function TodoList:is_empty()
    return self.total_count == 0
end

function TodoList:close_if_all_completed()
    if self.total_count > 0 and self.completed_count == self.total_count then
        self:clear()
        self._on_close()
    end
end

--- @type table<string, string>
local STATUS_CHECKBOX = {
    pending = "[ ]",
    in_progress = "[~]",
    completed = "[x]",
}

--- Render plan entries as markdown todo list
--- @param entries agentic.acp.PlanEntry[]
function TodoList:render(entries)
    local lines = {}
    local completed = 0

    for _, entry in ipairs(entries) do
        local checkbox = STATUS_CHECKBOX[entry.status]
            or STATUS_CHECKBOX.pending
        local line = string.format("- %s %s", checkbox, entry.content)
        table.insert(lines, line)

        if entry.status == "completed" then
            completed = completed + 1
        end
    end

    self.completed_count = completed
    self.total_count = #entries

    BufHelpers.with_modifiable(self._bufnr, function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end)

    if #entries > 0 then
        local context = string.format("%d of %d", completed, #entries)
        WindowDecoration.render_header(self._bufnr, "todos", context)
    end

    self._on_change(self)
    self:_scroll_to_non_completed(entries)
end

--- Scroll window to show at least 2 non-completed items
--- @param entries agentic.acp.PlanEntry[]
function TodoList:_scroll_to_non_completed(entries)
    local wins = vim.fn.win_findbuf(self._bufnr)
    if #wins == 0 then
        return
    end

    local winid = wins[1]
    local win_height = vim.api.nvim_win_get_height(winid)

    -- winbar takes 1 row from visible content area
    local winbar = vim.wo[winid].winbar
    if winbar and winbar ~= "" then
        win_height = win_height - 1
    end

    local total = #entries

    local first_non_completed = nil
    for i, e in ipairs(entries) do
        if e.status ~= "completed" then
            first_non_completed = i
            break
        end
    end

    if not first_non_completed or total <= win_height then
        return
    end

    local visible_lines = math.min(win_height, total)
    -- clamp to 0 to avoid ultra short windows, either by the user resize or window size.
    local target = first_non_completed - math.max(0, visible_lines - 2)
    local max_top = total - visible_lines + 1
    target = math.min(target, max_top)
    target = math.max(1, target)

    vim.api.nvim_win_call(winid, function()
        vim.fn.winrestview({ topline = target })
    end)
end

function TodoList:clear()
    self.completed_count = 0
    self.total_count = 0

    BufHelpers.with_modifiable(self._bufnr, function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)
end

return TodoList
