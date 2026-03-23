--- @class agentic.utils.list
local M = {}

--- Moves an item where item[key] == value to the head of a copy of the list.
--- @param items table[] Original array of tables
--- @param key string The key to match against
--- @param value any The value to find
--- @return table[] ordered_items New shallow copy of the list with the item at head
function M.move_to_head(items, key, value)
    -- Create a shallow copy to avoid mutating the original array
    local ordered_items = vim.list_extend({}, items)

    for i, item in ipairs(ordered_items) do
        if item[key] == value then
            table.remove(ordered_items, i)
            table.insert(ordered_items, 1, item)
            break
        end
    end

    return ordered_items
end

return M
