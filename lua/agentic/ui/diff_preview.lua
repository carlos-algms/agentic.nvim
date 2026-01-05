local DiffHighlighter = require("agentic.utils.diff_highlighter")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

local NS_DIFF = vim.api.nvim_create_namespace("agentic_diff_preview")

--- Builds a highlight map for all lines parsed as a block
--- @param lines string[]
--- @param lang string
--- @return table<number, table<number, string>>|nil row_col_hl Map of row -> col -> hl_group
local function build_highlight_map(lines, lang)
    if not lang or lang == "" or #lines == 0 then
        return nil
    end

    local content = table.concat(lines, "\n")

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
    if not ok or not parser then
        return nil
    end

    local trees = parser:parse()
    if not trees or #trees == 0 then
        return nil
    end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return nil
    end

    local row_col_hl = {}
    for i = 0, #lines - 1 do
        row_col_hl[i] = {}
    end

    for id, node in query:iter_captures(trees[1]:root(), content) do
        local name = query.captures[id]
        local start_row, start_col, end_row, end_col = node:range()
        local hl_group = "@" .. name .. "." .. lang

        for row = start_row, end_row do
            if row_col_hl[row] then
                local col_start = (row == start_row) and start_col or 0
                local col_end = (row == end_row) and end_col or #lines[row + 1]
                for col = col_start, col_end - 1 do
                    row_col_hl[row][col] = hl_group
                end
            end
        end
    end

    return row_col_hl
end

--- Get the diff highlight for a column position based on word-level change
--- @param col integer 0-indexed column
--- @param change? table Change info from find_inline_change
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- Builds virt_lines with syntax highlighting and diff background
--- @param new_lines string[]
--- @param old_lines? string[] Optional old lines for word-level diff
--- @param lang string
--- @return table virt_lines
local function get_highlighted_virt_lines(new_lines, old_lines, lang)
    local row_col_hl = build_highlight_map(new_lines, lang)

    local virt_lines = {}
    for row, line in ipairs(new_lines) do
        local col_hl = row_col_hl and row_col_hl[row - 1]
        local line_len = #line

        -- Find word-level change if we have corresponding old line
        local old_line = old_lines and old_lines[row]
        local change = old_line
            and DiffHighlighter.find_inline_change(old_line, line)

        -- No highlights or empty line: use word-level diff aware segments
        if not col_hl or line_len == 0 then
            if change then
                -- Split into segments based on word-level change
                local segments = {}
                if change.new_start > 0 then
                    table.insert(segments, {
                        line:sub(1, change.new_start),
                        Theme.HL_GROUPS.DIFF_ADD,
                    })
                end
                if change.new_end > change.new_start then
                    table.insert(segments, {
                        line:sub(change.new_start + 1, change.new_end),
                        Theme.HL_GROUPS.DIFF_ADD_WORD,
                    })
                end
                if change.new_end < line_len then
                    table.insert(segments, {
                        line:sub(change.new_end + 1),
                        Theme.HL_GROUPS.DIFF_ADD,
                    })
                end
                table.insert(
                    virt_lines,
                    #segments > 0 and segments
                        or { { line, Theme.HL_GROUPS.DIFF_ADD } }
                )
            else
                table.insert(virt_lines, { { line, Theme.HL_GROUPS.DIFF_ADD } })
            end
        else
            local segments = {}
            local current_hl = col_hl[0]
            local current_diff_hl = get_diff_hl_for_col(0, change)
            local seg_start = 0

            for col = 1, line_len do
                local hl = col_hl[col]
                local diff_hl = get_diff_hl_for_col(col, change)
                if hl ~= current_hl or diff_hl ~= current_diff_hl then
                    local text = line:sub(seg_start + 1, col)
                    local hl_spec = current_hl
                            and { current_hl, current_diff_hl }
                        or current_diff_hl
                    table.insert(segments, { text, hl_spec })
                    seg_start = col
                    current_hl = hl
                    current_diff_hl = diff_hl
                end
            end

            -- Final segment
            local text = line:sub(seg_start + 1)
            if #text > 0 then
                local hl_spec = current_hl and { current_hl, current_diff_hl }
                    or current_diff_hl
                table.insert(segments, { text, hl_spec })
            end

            table.insert(
                virt_lines,
                #segments > 0 and segments
                    or { { line, Theme.HL_GROUPS.DIFF_ADD } }
            )
        end
    end

    return virt_lines
end

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field target_winid number The window ID to display the diff in

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    local target_winid = opts.target_winid

    if not target_winid then
        return
    end

    -- Only show diff in normal mode to avoid disrupting user workflow
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "n" then
        return
    end

    local bufnr = vim.fn.bufnr(opts.file_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(opts.file_path)
    end

    -- Ensure the target window displays the diff buffer
    local ok, err = pcall(vim.api.nvim_win_set_buf, target_winid, bufnr)
    if not ok then
        Logger.notify("Failed to set buffer in window: " .. tostring(err))
        return
    end

    M.clear_diff(bufnr)

    local diff_blocks = ToolCallDiff.extract_diff_blocks({
        path = opts.file_path,
        old_text = opts.diff.old,
        new_text = opts.diff.new,
        replace_all = opts.diff.all,
        strict = true, -- don't show fallback if match fails
    })

    for _, block in ipairs(diff_blocks) do
        local old_count = #block.old_lines
        local new_count = #block.new_lines
        local is_modification = old_count == new_count and old_count > 0

        if old_count > 0 then
            for i, old_line in ipairs(block.old_lines) do
                local zero_indexed_line = block.start_line + i - 2

                -- Get corresponding new_line for word-level diff (only for modifications)
                local new_line = is_modification and block.new_lines[i] or nil

                -- Use DiffHighlighter for word-level diff support
                DiffHighlighter.apply_diff_highlights(
                    bufnr,
                    NS_DIFF,
                    zero_indexed_line,
                    old_line,
                    new_line
                )
            end
        end

        if new_count > 0 then
            -- For new files (old_count == 0), buffer is empty so anchor at line 0
            local anchor_line = old_count == 0 and 0
                or (block.end_line == 0 and 0 or block.end_line - 1)

            -- Get treesitter language for syntax highlighting
            local ft = vim.bo[bufnr].filetype
            local lang = vim.treesitter.language.get_lang(ft) or ft

            -- Pass old_lines for word-level diff (only for modifications)
            local old_lines_for_diff = is_modification and block.old_lines
                or nil
            local virt_lines = get_highlighted_virt_lines(
                block.new_lines,
                old_lines_for_diff,
                lang
            )

            ok, err = pcall(
                vim.api.nvim_buf_set_extmark,
                bufnr,
                NS_DIFF,
                anchor_line,
                0,
                {
                    virt_lines = virt_lines,
                    virt_lines_above = false,
                }
            )
            if not ok then
                Logger.notify("Failed to set virtual lines: " .. tostring(err))
            end
        end
    end

    if #diff_blocks > 0 then
        local first_block = diff_blocks[1]
        ok, err = pcall(
            vim.api.nvim_win_set_cursor,
            target_winid,
            { first_block.start_line, 0 }
        )
        if not ok then
            Logger.notify(
                "Failed to jump to first diff block: " .. tostring(err)
            )
        end
    end
end

--- Clears the diff highlights from the given buffer
--- @param buf number|string Buffer number or name
function M.clear_diff(buf)
    if type(buf) == "string" then
        buf = vim.fn.bufnr(buf)
    end

    if buf == -1 then
        return
    end

    return pcall(vim.api.nvim_buf_clear_namespace, buf, NS_DIFF, 0, -1)
end

return M
