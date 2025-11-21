---Reusable diff highlighting utility for both chat buffer and file buffer diffs
---@class agentic.utils.DiffHighlighter
local M = {}

---Find character-level changes between two lines
---@param old_line string
---@param new_line string
---@return {old_start: integer, old_end: integer, new_start: integer, new_end: integer}|nil
function M.find_inline_change(old_line, new_line)
    if old_line == new_line then
        return nil
    end

    -- Find common prefix
    local prefix_len = 0
    local min_len = math.min(#old_line, #new_line)
    for i = 1, min_len do
        if old_line:sub(i, i) == new_line:sub(i, i) then
            prefix_len = i
        else
            break
        end
    end

    -- Find common suffix (after the prefix)
    local suffix_len = 0
    for i = 1, min_len - prefix_len do
        if old_line:sub(#old_line - i + 1, #old_line - i + 1)
            == new_line:sub(#new_line - i + 1, #new_line - i + 1)
        then
            suffix_len = i
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

---Apply line-level and word-level highlights to a buffer using vim.highlight.range
---@param bufnr integer Buffer number
---@param ns_id integer Namespace ID for highlights
---@param line_number integer 0-indexed line number
---@param old_line string|nil Old line content (for deleted lines)
---@param new_line string|nil New line content (for added lines)
---@param is_modification boolean Whether this is a modification (both old and new exist)
function M.apply_diff_highlights(bufnr, ns_id, line_number, old_line, new_line, is_modification)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_number < 0 or line_number >= line_count then
        return
    end

    -- Apply line-level highlight for deleted lines
    if old_line and not new_line then
        -- Pure deletion - full line highlight
        vim.highlight.range(
            bufnr,
            ns_id,
            "AgenticDiffDelete",
            { line_number, 0 },
            { line_number, #old_line }
        )
    elseif new_line and not old_line then
        -- Pure addition - full line highlight
        vim.highlight.range(
            bufnr,
            ns_id,
            "AgenticDiffAdd",
            { line_number, 0 },
            { line_number, #new_line }
        )
    elseif old_line and new_line and is_modification then
        -- Modification: apply line-level highlight for old line
        vim.highlight.range(
            bufnr,
            ns_id,
            "AgenticDiffDelete",
            { line_number, 0 },
            { line_number, #old_line }
        )

        -- Find word-level changes
        local change = M.find_inline_change(old_line, new_line)
        if change and change.old_end > change.old_start then
            -- Word-level highlight for deleted portion (darker background, bold)
            vim.highlight.range(
                bufnr,
                ns_id,
                "AgenticDiffDeleteWord",
                { line_number, change.old_start },
                { line_number, change.old_end }
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
function M.apply_new_line_word_highlights(bufnr, ns_id, line_number, old_line, new_line)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_number < 0 or line_number >= line_count then
        return
    end

    -- Line-level highlight for new line
    vim.highlight.range(
        bufnr,
        ns_id,
        "AgenticDiffAdd",
        { line_number, 0 },
        { line_number, #new_line }
    )

    -- Find word-level changes
    local change = M.find_inline_change(old_line, new_line)
    if change and change.new_end > change.new_start then
        -- Word-level highlight for changed portion (darker background, bold)
        vim.highlight.range(
            bufnr,
            ns_id,
            "AgenticDiffAddWord",
            { line_number, change.new_start },
            { line_number, change.new_end }
        )
    end
end

return M
