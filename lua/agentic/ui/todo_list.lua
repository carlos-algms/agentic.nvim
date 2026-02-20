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

    vim.b[self._bufnr].agentic_todo_has_items = self.total_count > 0

    if #entries > 0 then
        local context = string.format("%d of %d", completed, #entries)
        WindowDecoration.render_header(self._bufnr, "todos", context)
    end

    self._on_change(self)
end

function TodoList:clear()
    self.completed_count = 0
    self.total_count = 0

    BufHelpers.with_modifiable(self._bufnr, function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end)

    vim.b[self._bufnr].agentic_todo_has_items = false
end

return TodoList
