local GLYPHS = {
    TOP_LEFT = "╭",
    BOTTOM_LEFT = "╰",
    HORIZONTAL = "─",
    VERTICAL = "│",
}

--- @class agentic.utils.ExtmarkBlock
local ExtmarkBlock = {}

--- Per-buffer cache of block ranges for statuscolumn rendering.
--- Maps bufnr -> sorted array of {start_row, end_row}.
--- @type table<integer, {start_row: integer, end_row: integer}[]>
ExtmarkBlock._block_cache = {}

--- Update the block cache for a buffer by reading NS_TOOL_BLOCKS extmarks.
--- @param bufnr integer
--- @param ns_id integer The NS_TOOL_BLOCKS namespace
function ExtmarkBlock.update_cache(bufnr, ns_id)
    local marks =
        vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
    local ranges = {}
    for _, m in ipairs(marks) do
        ranges[#ranges + 1] = {
            start_row = m[2],
            end_row = m[4].end_row,
        }
    end
    table.sort(ranges, function(a, b)
        return a.start_row < b.start_row
    end)
    ExtmarkBlock._block_cache[bufnr] = ranges
end

--- Clear cache for a buffer.
--- @param bufnr integer
function ExtmarkBlock.clear_cache(bufnr)
    ExtmarkBlock._block_cache[bufnr] = nil
end

--- Find the block range containing a 0-indexed line number using binary search.
--- @param ranges {start_row: integer, end_row: integer}[]
--- @param lnum integer 0-indexed line number
--- @return {start_row: integer, end_row: integer}|nil
local function find_block(ranges, lnum)
    local lo, hi = 1, #ranges
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local r = ranges[mid]
        if lnum < r.start_row then
            hi = mid - 1
        elseif lnum > r.end_row then
            lo = mid + 1
        else
            return r
        end
    end
    return nil
end

local HL = "%#AgenticCodeBlockFence#"
local RESET = "%*"
local PIPE = HL .. GLYPHS.VERTICAL .. " " .. RESET
local CORNER_TOP = HL .. GLYPHS.TOP_LEFT .. GLYPHS.HORIZONTAL .. RESET
local CORNER_BOTTOM = HL .. GLYPHS.BOTTOM_LEFT .. GLYPHS.HORIZONTAL .. RESET
local BLANK = "  "

--- Compute the glyph for a given line within a set of block ranges.
--- @param ranges {start_row: integer, end_row: integer}[]
--- @param lnum integer 0-indexed buffer line
--- @param virtnum integer 0 = first screen line, >0 = continuation
--- @return string
function ExtmarkBlock.glyph(ranges, lnum, virtnum)
    local r = find_block(ranges, lnum)
    if not r then
        return BLANK
    end

    if lnum == r.start_row and virtnum == 0 then
        return CORNER_TOP
    elseif lnum == r.end_row and virtnum == 0 then
        return CORNER_BOTTOM
    else
        return PIPE
    end
end

--- Statuscolumn function. Returns the glyph string for the current screen line.
--- @return string
function ExtmarkBlock.statuscolumn()
    local bufnr = vim.api.nvim_get_current_buf()
    local ranges = ExtmarkBlock._block_cache[bufnr]
    if not ranges or #ranges == 0 then
        return BLANK
    end
    return ExtmarkBlock.glyph(ranges, vim.v.lnum - 1, vim.v.virtnum)
end

return ExtmarkBlock
