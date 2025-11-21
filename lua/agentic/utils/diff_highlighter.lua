---Reusable diff highlighting utility for both chat buffer and file buffer diffs
---@class agentic.utils.DiffHighlighter
local M = {}

local Theme = require("agentic.theme")

---Find character-level changes between two lines (UTF-8 aware)
---@param old_line string
---@param new_line string
---@return {old_start: integer, old_end: integer, new_start: integer, new_end: integer}|nil
function M.find_inline_change(old_line, new_line)
    if old_line == new_line then
        return nil
    end

    -- Convert strings to grapheme arrays for UTF-8 safe comparison
    local old_graphemes = {}
    for g in vim.iter.graphemes(old_line) do
        table.insert(old_graphemes, g)
    end

    local new_graphemes = {}
    for g in vim.iter.graphemes(new_line) do
        table.insert(new_graphemes, g)
    end

    -- Find common prefix
    local prefix_len = 0
    local min_len = math.min(#old_graphemes, #new_graphemes)
    for i = 1, min_len do
        if old_graphemes[i] == new_graphemes[i] then
            prefix_len = prefix_len + #old_graphemes[i]
        else
            break
        end
    end

    -- Find common suffix (after the prefix)
    local suffix_len = 0
    for i = 1, min_len - prefix_len do
        local old_char = old_graphemes[#old_graphemes - i + 1]
        local new_char = new_graphemes[#new_graphemes - i + 1]
        if old_char == new_char then
            suffix_len = suffix_len + #old_char
        else
            break
        end
    end

    -- Calculate change regions
    local old_start = prefix_len
    local old_end = #old_line - suffix_len
    local new_start = prefix_len
    local new_end = #new_line - suffix_len

    -- If no changes found, return nil
    if old_start >= old_end and new_start >= new_end then
        return nil
    end

    return {
        old_start = old_start,
        old_end = old_end,
        new_start = new_start,
        new_end = new_end,
    }
end

---@param bufnr integer
---@param line_number integer 0-indexed line number
---@return boolean valid
local function validate_buffer_line(bufnr, line_number)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    return line_number >= 0 and line_number < line_count
end

---@param bufnr integer
---@param ns_id integer
---@param line_number integer
---@param line_content string
local function apply_add_line_highlight(bufnr, ns_id, line_number, line_content)
    vim.highlight.range(
        bufnr,
        ns_id,
        Theme.HL_GROUPS.DIFF_ADD,
        { line_number, 0 },
        { line_number, #line_content }
    )
end

---Apply line-level and word-level highlights to a buffer using vim.highlight.range
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID for highlights
---@param line_number integer 0-indexed line number
---@param old_line string|nil Old line content (for deleted lines)
---@param new_line string|nil New line content (for added lines)
function M.apply_diff_highlights(bufnr, ns_id, line_number, old_line, new_line)
    if not validate_buffer_line(bufnr, line_number) then
        return
    end

    -- Apply line-level highlight for deleted lines
    if old_line and not new_line then
        -- Pure deletion - full line highlight
        vim.highlight.range(
            bufnr,
            ns_id,
            Theme.HL_GROUPS.DIFF_DELETE,
            { line_number, 0 },
            { line_number, #old_line }
        )
    elseif new_line and not old_line then
        -- Pure addition - full line highlight
        apply_add_line_highlight(bufnr, ns_id, line_number, new_line)
    elseif old_line and new_line then
        -- Modification: find word-level changes first to avoid redundant highlights
        local change = M.find_inline_change(old_line, new_line)
        if change and change.old_end > change.old_start then
            -- Only apply line-level highlight if change doesn't span entire line
            if change.old_start > 0 or change.old_end < #old_line then
                vim.highlight.range(
                    bufnr,
                    ns_id,
                    Theme.HL_GROUPS.DIFF_DELETE,
                    { line_number, 0 },
                    { line_number, #old_line }
                )
            end
            -- Word-level highlight for deleted portion (darker background, bold)
            vim.highlight.range(
                bufnr,
                ns_id,
                Theme.HL_GROUPS.DIFF_DELETE_WORD,
                { line_number, change.old_start },
                { line_number, change.old_end }
            )
        else
            -- Entire line changed, apply line-level highlight only
            vim.highlight.range(
                bufnr,
                ns_id,
                Theme.HL_GROUPS.DIFF_DELETE,
                { line_number, 0 },
                { line_number, #old_line }
            )
        end
    end
end

---Apply word-level highlight for new line (used when new line is on separate line)
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID for highlights
---@param line_number integer 0-indexed line number
---@param old_line string Old line content
---@param new_line string New line content
function M.apply_new_line_word_highlights(
    bufnr,
    ns_id,
    line_number,
    old_line,
    new_line
)
    if not validate_buffer_line(bufnr, line_number) then
        return
    end

    -- Find word-level changes first to avoid overlapping highlights
    local change = M.find_inline_change(old_line, new_line)
    if change and change.new_end > change.new_start then
        -- Only apply line-level highlight if change doesn't span entire line
        if change.new_start > 0 or change.new_end < #new_line then
            apply_add_line_highlight(bufnr, ns_id, line_number, new_line)
        end
        -- Word-level highlight for changed portion (darker background, bold)
        vim.highlight.range(
            bufnr,
            ns_id,
            Theme.HL_GROUPS.DIFF_ADD_WORD,
            { line_number, change.new_start },
            { line_number, change.new_end }
        )
    else
        -- Entire line changed, apply line-level highlight only
        apply_add_line_highlight(bufnr, ns_id, line_number, new_line)
    end
end

return M
