local ToolCallDiff = require("agentic.ui.tool_call_diff")
local Theme = require("agentic.theme")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

local NS_DIFF = vim.api.nvim_create_namespace("agentic_diff_preview")

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field target_winid? number The window ID to display the diff in

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
        return
    end

    -- Ensure the target window displays the diff buffer
    local ok, err = pcall(vim.api.nvim_win_set_buf, target_winid, bufnr)
    if not ok then
        vim.notify(
            "Failed to set buffer in window: " .. tostring(err),
            vim.log.levels.WARN
        )
        return
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
