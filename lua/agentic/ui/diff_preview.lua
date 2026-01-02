local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Theme = require("agentic.theme")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}
M.__index = M

local NS_DIFF = vim.api.nvim_create_namespace("agentic_diff_preview")

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field widget_windows table<string, number|nil> The chat widget sidebar windows - These are considered locked and we should find other windows to display the diff in

--- Finds the first window on the current tabpage that is NOT part of the chat widget
--- @param widget_windows table<string, number|nil> The chat widget window IDs to exclude
--- @return number|nil winid The first non-widget window ID, or nil if none found
local function find_first_non_widget_window(widget_windows)
    local current_tabpage = vim.api.nvim_get_current_tabpage()
    local all_windows = vim.api.nvim_tabpage_list_wins(current_tabpage)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(widget_windows) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            return winid
        end
    end

    return nil
end

--- Opens a new window on the left side with full height
--- @param bufnr number The buffer to display in the new window
--- @return number winid The newly created window ID
local function open_left_window(bufnr)
    local winid = vim.api.nvim_open_win(bufnr, true, {
        split = "left",
        win = -1,
    })
    return winid
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    local bufnr = vim.fn.bufnr(opts.file_path)

    if bufnr == -1 then
        return
    end

    local target_winid = find_first_non_widget_window(opts.widget_windows)

    if not target_winid then
        target_winid = open_left_window(bufnr)
    end

    M.clear_diff(bufnr)

    local diff_blocks = ToolCallDiff.extract_diff_blocks(
        opts.file_path,
        opts.diff.old,
        opts.diff.new,
        opts.diff.all
    )

    for _, block in ipairs(diff_blocks) do
        if #block.old_lines > 0 then
            for line_idx = block.start_line, block.end_line do
                -- Convert to 0-indexed
                local zero_indexed_line = line_idx - 1

                -- Get the line length to highlight only the text
                local line_content = vim.api.nvim_buf_get_lines(
                    bufnr,
                    zero_indexed_line,
                    zero_indexed_line + 1,
                    false
                )[1] or ""
                local line_len = #line_content

                local ok, err = pcall(
                    vim.api.nvim_buf_set_extmark,
                    bufnr,
                    NS_DIFF,
                    zero_indexed_line,
                    0,
                    {
                        end_row = zero_indexed_line,
                        end_col = line_len,
                        hl_group = Theme.HL_GROUPS.DIFF_DELETE,
                    }
                )
                if not ok then
                    vim.notify(
                        "Failed to set deletion highlight: " .. tostring(err),
                        vim.log.levels.WARN
                    )
                end
            end
        end

        if #block.new_lines > 0 then
            local anchor_line = block.end_line == 0 and 0 or block.end_line - 1

            local virt_lines = {}
            for _, new_line in ipairs(block.new_lines) do
                table.insert(virt_lines, {
                    { new_line, Theme.HL_GROUPS.DIFF_ADD },
                })
            end

            local ok, err = pcall(
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
                vim.notify(
                    "Failed to set virtual lines: " .. tostring(err),
                    vim.log.levels.WARN
                )
            end
        end
    end

    if #diff_blocks > 0 then
        local first_block = diff_blocks[1]
        local ok, err = pcall(
            vim.api.nvim_win_set_cursor,
            target_winid,
            { first_block.start_line, 0 }
        )
        if not ok then
            vim.notify(
                "Failed to jump to first diff block: " .. tostring(err),
                vim.log.levels.WARN
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
