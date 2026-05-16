local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local ToolCallBlocks = require("agentic.ui.tool_call_blocks")

local HEADING_QUERY = [[
(atx_heading (atx_h1_marker)) @heading
(atx_heading (atx_h2_marker)) @heading
(atx_heading (atx_h3_marker)) @heading
]]

--- @type vim.treesitter.Query|nil
local HEADING_TS_QUERY
do
    local ok, query =
        pcall(vim.treesitter.query.parse, "markdown", HEADING_QUERY)
    if ok then
        HEADING_TS_QUERY = query
    end
end

local ChatNavigation = {}

--- @param count integer|nil
--- @return integer count
local function normalize_count(count)
    if type(count) == "number" and count > 0 then
        return count
    end
    return vim.v.count1
end

--- @param row integer|nil
local function jump_to_row(row)
    if not row then
        return
    end

    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
end

--- @param bufnr integer
--- @return integer[] rows
local function heading_rows(bufnr)
    if not HEADING_TS_QUERY or not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    local ok_parser, parser =
        pcall(vim.treesitter.get_parser, bufnr, "markdown")
    if not ok_parser or not parser then
        return {}
    end

    local ok_trees, trees = pcall(function()
        return parser:parse()
    end)
    if not ok_trees or not trees or not trees[1] then
        return {}
    end

    local rows = {}
    for _, node in HEADING_TS_QUERY:iter_captures(trees[1]:root(), bufnr) do
        local start_row = node:range()
        table.insert(rows, start_row)
    end

    return rows
end

--- @param bufnr integer
--- @param direction integer
--- @param count integer
--- @param cursor_row integer
--- @return integer|nil row
function ChatNavigation.heading_target_row(bufnr, direction, count, cursor_row)
    if count < 1 then
        return nil
    end

    local rows = heading_rows(bufnr)
    local seen = 0

    if direction > 0 then
        for _, row in ipairs(rows) do
            if row > cursor_row then
                seen = seen + 1
                if seen == count then
                    return row
                end
            end
        end
    else
        for i = #rows, 1, -1 do
            local row = rows[i]
            if row < cursor_row then
                seen = seen + 1
                if seen == count then
                    return row
                end
            end
        end
    end

    return nil
end

--- @param bufnr integer
function ChatNavigation.setup_keymaps(bufnr)
    local keymaps = Config.keymaps.chat

    --- @type { key: agentic.UserConfig.KeymapValue, fn: fun(bufnr: integer, count: integer|nil), desc: string }[]
    local bindings = {
        {
            key = keymaps.next_heading,
            fn = ChatNavigation.next_heading,
            desc = "Agentic: Next chat heading",
        },
        {
            key = keymaps.prev_heading,
            fn = ChatNavigation.prev_heading,
            desc = "Agentic: Previous chat heading",
        },
        {
            key = keymaps.next_tool_call,
            fn = ChatNavigation.next_tool_call,
            desc = "Agentic: Next tool call",
        },
        {
            key = keymaps.prev_tool_call,
            fn = ChatNavigation.prev_tool_call,
            desc = "Agentic: Previous tool call",
        },
    }

    for _, binding in ipairs(bindings) do
        BufHelpers.multi_keymap_set(binding.key, bufnr, function()
            binding.fn(bufnr)
        end, { desc = binding.desc })
    end
end

--- @param bufnr integer
--- @param count integer|nil
function ChatNavigation.next_heading(bufnr, count)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local row = ChatNavigation.heading_target_row(
        bufnr,
        1,
        normalize_count(count),
        cursor_row
    )
    jump_to_row(row)
end

--- @param bufnr integer
--- @param count integer|nil
function ChatNavigation.prev_heading(bufnr, count)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local row = ChatNavigation.heading_target_row(
        bufnr,
        -1,
        normalize_count(count),
        cursor_row
    )
    jump_to_row(row)
end

--- @param bufnr integer
--- @param count integer|nil
function ChatNavigation.next_tool_call(bufnr, count)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local row = ToolCallBlocks.navigation_target_row(
        bufnr,
        1,
        normalize_count(count),
        cursor_row
    )
    jump_to_row(row)
end

--- @param bufnr integer
--- @param count integer|nil
function ChatNavigation.prev_tool_call(bufnr, count)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local row = ToolCallBlocks.navigation_target_row(
        bufnr,
        -1,
        normalize_count(count),
        cursor_row
    )
    jump_to_row(row)
end

return ChatNavigation
