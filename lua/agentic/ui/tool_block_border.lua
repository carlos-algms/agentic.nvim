local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

local GLYPHS = {
    TOP_LEFT = "╭",
    BOTTOM_LEFT = "╰",
    HORIZONTAL = "─",
    VERTICAL = "│",
}

local BLANK = " "

local STATUSCOLUMN_EXPR =
    "%!v:lua.require'agentic.ui.tool_block_border'.statuscolumn()"

--- @class agentic.ui.ToolBlockBorder.Range
--- @field start_row integer
--- @field end_row integer

--- @class agentic.ui.ToolBlockBorder
local ToolBlockBorder = {
    NS_TOOL_BLOCKS = NS_TOOL_BLOCKS,
    STATUSCOLUMN_EXPR = STATUSCOLUMN_EXPR,
}

--- @return integer|nil bufnr
local function statuscolumn_bufnr()
    local winid = vim.g.statusline_winid
    if type(winid) == "number" and vim.api.nvim_win_is_valid(winid) then
        return vim.api.nvim_win_get_buf(winid)
    end
    local current = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(current) then
        return current
    end
    return nil
end

--- @param text string
--- @return string text
local function with_highlight(text)
    return "%#" .. Theme.HL_GROUPS.CODE_BLOCK_FENCE .. "#" .. text .. "%*"
end

--- @param bufnr integer
--- @param row integer
--- @return agentic.ui.ToolBlockBorder.Range|nil range
function ToolBlockBorder.block_range_at_row(bufnr, row)
    if row < 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local ok, extmarks = pcall(
        vim.api.nvim_buf_get_extmarks,
        bufnr,
        NS_TOOL_BLOCKS,
        {
            row,
            0,
        },
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

    --- @type agentic.ui.ToolBlockBorder.Range
    local range = {
        start_row = start_row,
        end_row = end_row,
    }
    return range
end

--- @param bufnr integer
--- @param row integer
--- @param virtnum integer
--- @return string glyph
function ToolBlockBorder.glyph_for_line(bufnr, row, virtnum)
    if virtnum < 0 then
        return BLANK
    end

    local range = ToolBlockBorder.block_range_at_row(bufnr, row)
    if not range then
        return BLANK
    end

    if virtnum > 0 then
        return GLYPHS.VERTICAL
    end

    if row == range.start_row then
        return GLYPHS.TOP_LEFT
    end

    if row == range.end_row then
        return GLYPHS.BOTTOM_LEFT
    end

    return GLYPHS.VERTICAL
end

--- @return string text
local function render_statuscolumn()
    local bufnr = statuscolumn_bufnr()
    if not bufnr then
        return BLANK
    end

    local glyph =
        ToolBlockBorder.glyph_for_line(bufnr, vim.v.lnum - 1, vim.v.virtnum)
    if glyph == BLANK then
        return BLANK
    end

    return with_highlight(glyph)
end

--- @return string text
function ToolBlockBorder.statuscolumn()
    local ok, text = pcall(render_statuscolumn)
    if ok then
        return text
    end
    return BLANK
end

return ToolBlockBorder
