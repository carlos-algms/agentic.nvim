local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.ui.TodoList
local TodoList = {}

--- Map status to checkbox format
--- @param status "pending" | "in_progress" | "completed"
--- @return string checkbox
local function status_to_checkbox(status)
    if status == "pending" then
        return "[ ]"
    elseif status == "in_progress" then
        return "[~]"
    elseif status == "completed" then
        return "[x]"
    end
    return "[ ]"
end

--- Render plan entries as markdown todo list
--- @param bufnr integer
--- @param entries agentic.acp.PlanEntry[]
function TodoList.render(bufnr, entries)
    local lines = {}
    for _, entry in ipairs(entries) do
        local checkbox = status_to_checkbox(entry.status)
        local line = string.format("- %s %s", checkbox, entry.content) -- not adding priority for now, it's not aggregating much visual value
        table.insert(lines, line)
    end

    BufHelpers.with_modifiable(bufnr, function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end)
end

return TodoList
