local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")
local Theme = require("agentic.theme")

local CODE_FENCE_QUERY = "(fenced_code_block) @code_fence"

--- @class agentic.ui.CodeSelection
--- @field _selections agentic.Selection[]
--- @field _bufnr integer the same buffer number as the ChatWidget's code selection buffer
--- @field _on_change fun(codeSelection: agentic.ui.CodeSelection)
local CodeSelection = {}
CodeSelection.__index = CodeSelection

--- @param bufnr integer The code selection buffer number from ChatWidget
--- @param on_change fun(codeSelection: agentic.ui.CodeSelection) Callback to trigger when selection list changes (e.g., update header)
--- @return agentic.ui.CodeSelection
function CodeSelection:new(bufnr, on_change)
    local instance = setmetatable({
        _selections = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings()

    return instance
end

--- @param selection agentic.Selection
function CodeSelection:add(selection)
    if selection and #selection.lines > 0 then
        table.insert(self._selections, selection)
        self:_render()
    end
end

--- @param line integer The cursor line number
function CodeSelection:remove_at_cursor(line)
    local root = self:_get_tree_root()
    if not root then
        return
    end

    -- Find the code fence block that contains the cursor line
    local query = vim.treesitter.query.parse("markdown", CODE_FENCE_QUERY)

    local fence_index = nil
    local match_count = 0

    for _, node in query:iter_captures(root, self._bufnr, 0, -1) do
        match_count = match_count + 1
        local start_row, _, end_row, _ = node:range()

        -- Convert to 1-indexed line numbers
        if line >= start_row + 1 and line <= end_row + 1 then
            fence_index = match_count
            break
        end
    end

    if fence_index and fence_index <= #self._selections then
        table.remove(self._selections, fence_index)
        self:_render()
    end
end

--- @param start_line integer
--- @param end_line integer
function CodeSelection:remove_range(start_line, end_line)
    local root = self:_get_tree_root()
    if not root then
        return
    end

    local query = vim.treesitter.query.parse("markdown", CODE_FENCE_QUERY)

    -- Collect indices of fences that overlap with the selection range
    local indices_to_remove = {}
    local match_count = 0

    for _, node in query:iter_captures(root, self._bufnr, 0, -1) do
        match_count = match_count + 1
        local fence_start, _, fence_end, _ = node:range()

        -- Convert to 1-indexed and check if fence overlaps with selection
        if
            (start_line >= fence_start + 1 and start_line <= fence_end + 1)
            or (end_line >= fence_start + 1 and end_line <= fence_end + 1)
            or (start_line <= fence_start + 1 and end_line >= fence_end + 1)
        then
            table.insert(indices_to_remove, match_count)
        end
    end

    -- Remove in reverse order to maintain correct indices
    for i = #indices_to_remove, 1, -1 do
        local idx = indices_to_remove[i]
        if idx <= #self._selections then
            table.remove(self._selections, idx)
        end
    end

    if #indices_to_remove > 0 then
        self:_render()
    end
end

--- @return agentic.Selection[]
function CodeSelection:get_selections()
    return vim.deepcopy(self._selections)
end

function CodeSelection:clear()
    self._selections = {}
    self:_render()
end

--- @return boolean
function CodeSelection:is_empty()
    return #self._selections == 0
end

--- @private
--- @return TSNode|nil root
function CodeSelection:_get_tree_root()
    local parser = vim.treesitter.get_parser(self._bufnr, "markdown")
    if not parser then
        return nil
    end

    local tree = parser:parse()[1]
    if not tree then
        return nil
    end

    return tree:root()
end

--- @private
function CodeSelection:_render()
    if #self._selections == 0 then
        BufHelpers.with_modifiable(self._bufnr, function(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
        end)
        self._on_change(self)
        return
    end

    local lines = {}

    for _, selection in ipairs(self._selections) do
        local snippet = table.concat(selection.lines, "\n")
        local code_fence = string.format(
            "```%s %s#L%d-L%d\n%s\n```",
            selection.file_type,
            selection.file_path,
            selection.start_line,
            selection.end_line,
            snippet
        )

        -- Split the code fence into lines for buffer insertion
        for line in code_fence:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
    end

    BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)

    self._on_change(self)
end

--- @return agentic.Selection|nil
function CodeSelection.get_selected_text()
    local mode = vim.fn.mode()

    if mode == "v" or mode == "V" then
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        local lines = vim.api.nvim_buf_get_lines(
            0,
            start_line - 1, -- 0-indexed
            end_line, -- exclusive
            false
        )

        -- exit visual mode to avoid issues with the input buffer
        BufHelpers.feed_ESC_key()

        local buf_name = vim.api.nvim_buf_get_name(0)

        --- @class agentic.Selection
        local selection = {
            lines = lines,
            start_line = start_line,
            end_line = end_line,
            file_path = FileSystem.to_smart_path(buf_name),
            file_type = Theme.get_language_from_path(buf_name),
        }

        return selection
    end
end

--- @private
function CodeSelection:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "d", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = cursor[1]

        self:remove_at_cursor(line)
    end, { nowait = true })

    BufHelpers.keymap_set(self._bufnr, "v", "d", function()
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        self:remove_range(start_line, end_line)

        -- Exit visual mode
        BufHelpers.feed_ESC_key()
    end, { nowait = true })
end

return CodeSelection
