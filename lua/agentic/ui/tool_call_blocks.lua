--- @class agentic.ui.ToolCallBlocks
local ToolCallBlocks = {}

ToolCallBlocks.NS_TOOL_BLOCKS =
    vim.api.nvim_create_namespace("agentic_tool_blocks")

--- Number of lines between a block's start_row and its body's first line.
--- Layout: row 0 = header line, row 1 = blank separator, row 2 = body start.
--- Kept in sync with `MessageWriter:_prepare_block_lines`.
ToolCallBlocks.HEADER_HEIGHT = 2

--- @class agentic.ui.ToolCallBlocks.Range
--- @field start_row integer
--- @field end_row integer

--- @param bufnr integer
--- @param row integer
--- @return agentic.ui.ToolCallBlocks.Range|nil range
function ToolCallBlocks.block_range_at_row(bufnr, row)
    if row < 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local ok, extmarks = pcall(
        vim.api.nvim_buf_get_extmarks,
        bufnr,
        ToolCallBlocks.NS_TOOL_BLOCKS,
        { row, 0 },
        { row, -1 },
        {
            details = true,
            limit = 1,
            overlap = true,
        }
    )

    if not ok or not extmarks or not extmarks[1] then
        return nil
    end

    local extmark = extmarks[1]
    local start_row = extmark[2]
    local details = extmark[4] or {}
    local end_row = details.end_row

    if not end_row or row < start_row or row > end_row then
        return nil
    end

    --- @type agentic.ui.ToolCallBlocks.Range
    local range = {
        start_row = start_row,
        end_row = end_row,
    }
    return range
end

--- @param bufnr integer
--- @param direction integer
--- @param count integer
--- @param cursor_row integer
--- @return integer|nil row
function ToolCallBlocks.navigation_target_row(
    bufnr,
    direction,
    count,
    cursor_row
)
    if count < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    --- @type integer[]|integer
    local start
    --- @type integer[]|integer
    local finish

    if direction > 0 then
        start = { cursor_row + 1, 0 }
        finish = -1
    elseif cursor_row > 0 then
        -- When cursor sits inside a block, jump past its anchor so the
        -- backward search lands on the previous block, not the current one.
        local current = ToolCallBlocks.block_range_at_row(bufnr, cursor_row)
        local search_from = current and current.start_row or cursor_row
        if search_from <= 0 then
            return nil
        end
        start = { search_from - 1, -1 }
        finish = { 0, 0 }
    else
        return nil
    end

    local ok, extmarks = pcall(
        vim.api.nvim_buf_get_extmarks,
        bufnr,
        ToolCallBlocks.NS_TOOL_BLOCKS,
        start,
        finish,
        { limit = count }
    )

    if not ok or not extmarks or not extmarks[count] then
        return nil
    end

    return extmarks[count][2] + ToolCallBlocks.HEADER_HEIGHT
end

return ToolCallBlocks
