---@class agentic.utils.DiffFormatter
local M = {}

---Format diff blocks as plain text lines with highlight information
---@param diff_blocks_by_file table<string, DiffBlock[]> Maps file path to diff blocks
---@return string[] formatted_lines Array of formatted lines ready for buffer
---@return table[] highlight_ranges Array of highlight info: {line_index, type, old_line?, new_line?, is_modification?}
function M.format_diff_blocks(diff_blocks_by_file)
    local formatted_lines = {}
    local highlight_ranges = {}

    for path, diff_blocks in pairs(diff_blocks_by_file) do
        if #diff_blocks == 0 then
            -- Skip empty diff blocks
            goto continue
        end

        -- Process each diff block
        for _, diff_block in ipairs(diff_blocks) do
            local old_count = #diff_block.old_lines
            local new_count = #diff_block.new_lines

            -- Skip empty blocks
            if old_count == 0 and new_count == 0 then
                goto next_block
            end

            local is_modification = old_count == new_count and old_count > 0

            -- Output old lines (to be deleted) - show as plain text with highlight
            for i, old_line in ipairs(diff_block.old_lines) do
                local line_index = #formatted_lines
                table.insert(formatted_lines, old_line)

                local new_line = is_modification and diff_block.new_lines[i] or nil
                table.insert(highlight_ranges, {
                    line_index = line_index,
                    type = "old",
                    old_line = old_line,
                    new_line = new_line,
                    is_modification = is_modification,
                })
            end

            -- Output new lines (incoming) - show as plain text with highlight
            for i, new_line in ipairs(diff_block.new_lines) do
                local line_index = #formatted_lines
                table.insert(formatted_lines, new_line)

                -- Only add highlight info if this is NOT a modification (modifications already handled above)
                if not is_modification then
                    table.insert(highlight_ranges, {
                        line_index = line_index,
                        type = "new",
                        old_line = nil,
                        new_line = new_line,
                        is_modification = false,
                    })
                else
                    -- For modifications, we need to apply word-level highlights to the new line
                    local old_line = diff_block.old_lines[i]
                    table.insert(highlight_ranges, {
                        line_index = line_index,
                        type = "new_modification",
                        old_line = old_line,
                        new_line = new_line,
                        is_modification = true,
                    })
                end
            end

            ::next_block::
        end

        ::continue::
    end

    return formatted_lines, highlight_ranges
end

return M
