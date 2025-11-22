local P = {}

---@class agentic.DiffHandler.DiffBlock
---@field start_line integer
---@field end_line integer
---@field old_lines string[]
---@field new_lines string[]

---@class agentic.acp.ACPDiffHandler
local M = {}

local TextMatcher = require("agentic.utils.text_matcher")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

---@param tool_call agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@return boolean has_diff
function M.has_diff_content(tool_call)
    -- We use rawInput for diffs. Old string might be nil for new files.
    -- We check for file_path and new_string presence.
    return tool_call.rawInput ~= nil
        and tool_call.rawInput.file_path ~= nil
        and tool_call.rawInput.new_string ~= nil
end

---@param tool_call agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@return table<string, agentic.DiffHandler.DiffBlock[]> diff_blocks_by_file Maps file path to list of diff blocks
function M.extract_diff_blocks(tool_call)
    ---@type table<string, agentic.DiffHandler.DiffBlock[]>
    local diff_blocks_by_file = {}

    local path = tool_call.rawInput.file_path
    local oldText = tool_call.rawInput.old_string
    local newText = tool_call.rawInput.new_string

    -- Default replace_all to true if not specified, unless explicitly false
    local replace_all = tool_call.rawInput.replace_all ~= false

    if not path or not newText then
        return diff_blocks_by_file
    end

    if not oldText or oldText == "" then
        local new_lines = P._normalize_text_to_lines(newText)
        P._add_diff_block(
            diff_blocks_by_file,
            path,
            P._create_new_file_diff_block(new_lines)
        )
    else
        local old_lines = P._normalize_text_to_lines(oldText)
        local new_lines = P._normalize_text_to_lines(newText)

        local abs_path = FileSystem.to_absolute_path(path)
        local file_lines = FileSystem.read_from_buffer_or_disk(abs_path) or {}

        local blocks =
            P._match_or_substring_fallback(file_lines, old_lines, new_lines)
        if blocks then
            if replace_all then
                for _, block in ipairs(blocks) do
                    P._add_diff_block(diff_blocks_by_file, path, block)
                end
            else
                -- Only use the first match if replace_all is false
                P._add_diff_block(diff_blocks_by_file, path, blocks[1])
            end
        else
            Logger.debug("[ACP diff] Failed to locate diff", { path = path })
            -- Fallback: display the diff even if we can't match it
            P._add_diff_block(diff_blocks_by_file, path, {
                start_line = 1,
                end_line = #old_lines,
                old_lines = old_lines,
                new_lines = new_lines,
            })
        end
    end

    for file_path, diff_blocks in pairs(diff_blocks_by_file) do
        table.sort(diff_blocks, function(a, b)
            return a.start_line < b.start_line
        end)
        diff_blocks_by_file[file_path] = P._minimize_diff_blocks(diff_blocks)
    end

    return diff_blocks_by_file
end

---Minimize diff blocks by removing unchanged lines using vim.diff
---@param diff_blocks agentic.DiffHandler.DiffBlock[]
---@return agentic.DiffHandler.DiffBlock[]
function P._minimize_diff_blocks(diff_blocks)
    ---@type agentic.DiffHandler.DiffBlock[]
    local minimized = {}

    for _, diff_block in ipairs(diff_blocks) do
        local old_string = table.concat(diff_block.old_lines, "\n")
        local new_string = table.concat(diff_block.new_lines, "\n")

        local patch = vim.diff(old_string, new_string, {
            algorithm = "histogram",
            result_type = "indices",
            ctxlen = 0,
        }) --[[ @as integer[][] ]]

        if #patch > 0 then
            for _, hunk in ipairs(patch) do
                local start_a, count_a, start_b, count_b = unpack(hunk)
                local minimized_block = {}

                if count_a > 0 then
                    local end_a =
                        math.min(start_a + count_a - 1, #diff_block.old_lines)
                    minimized_block.old_lines =
                        vim.list_slice(diff_block.old_lines, start_a, end_a)
                    minimized_block.start_line = diff_block.start_line
                        + start_a
                        - 1
                    minimized_block.end_line = minimized_block.start_line
                        + count_a
                        - 1
                else
                    minimized_block.old_lines = {}
                    -- For insertions, start_line is the position before which to insert
                    minimized_block.start_line = diff_block.start_line + start_a
                    minimized_block.end_line = minimized_block.start_line - 1
                end
                if count_b > 0 then
                    local end_b =
                        math.min(start_b + count_b - 1, #diff_block.new_lines)
                    minimized_block.new_lines =
                        vim.list_slice(diff_block.new_lines, start_b, end_b)
                else
                    minimized_block.new_lines = {}
                end
                table.insert(minimized, minimized_block)
            end
        else
            -- If vim.diff returns empty patch but we have changes, include the full block
            -- This handles edge cases where the diff algorithm doesn't detect changes
            if old_string ~= new_string then
                table.insert(minimized, diff_block)
            end
        end
    end

    table.sort(minimized, function(a, b)
        return a.start_line < b.start_line
    end)

    return minimized
end

---Create a diff block for a new file
---@param new_lines string[]
---@return agentic.DiffHandler.DiffBlock
function P._create_new_file_diff_block(new_lines)
    local line_count = #new_lines

    ---@type agentic.DiffHandler.DiffBlock
    local block = {
        start_line = 1,
        end_line = line_count > 0 and line_count or 1,
        old_lines = {},
        new_lines = new_lines,
    }

    return block
end

---Normalize text to lines array, handling nil and vim.NIL
---@param text string|nil
---@return string[]
function P._normalize_text_to_lines(text)
    if not text or text == "" or text == vim.NIL then
        return {}
    end

    if type(text) == "string" then
        return vim.split(text, "\n")
    end

    return {}
end

---Add a diff block to the collection, ensuring the path array exists
---@param diff_blocks_by_file table<string, agentic.DiffHandler.DiffBlock[]>
---@param path string
---@param diff_block agentic.DiffHandler.DiffBlock
function P._add_diff_block(diff_blocks_by_file, path, diff_block)
    diff_blocks_by_file[path] = diff_blocks_by_file[path] or {}
    table.insert(diff_blocks_by_file[path], diff_block)
end

---Try fuzzy match for all occurrences, fallback to substring replacement for single-line cases
---@param file_lines string[] File content lines
---@param old_lines string[] Old text lines
---@param new_lines string[] New text lines
---@return agentic.DiffHandler.DiffBlock[]|nil blocks Array of diff blocks or nil if no match
function P._match_or_substring_fallback(file_lines, old_lines, new_lines)
    -- Find all matches using fuzzy matching
    local matches = TextMatcher.find_all_matches(file_lines, old_lines)

    if #matches > 0 then
        ---@type agentic.DiffHandler.DiffBlock[]
        local blocks = {}

        for _, match in ipairs(matches) do
            ---@type agentic.DiffHandler.DiffBlock
            local block = {
                start_line = match.start_line,
                end_line = match.end_line,
                old_lines = old_lines,
                new_lines = new_lines,
            }

            table.insert(blocks, block)
        end

        return blocks
    end

    -- Fallback to substring replacement for single-line cases
    if #old_lines == 1 and #new_lines == 1 then
        local blocks = P._find_substring_replacements(
            file_lines,
            old_lines[1],
            new_lines[1]
        )

        return #blocks > 0 and blocks or nil
    end

    return nil
end

---Find all substring replacement occurrences in file lines
---@param file_lines string[] File content lines
---@param search_text string Text to search for
---@param replace_text string Text to replace with
---@return agentic.DiffHandler.DiffBlock[] diff_blocks Array of diff blocks (empty if no matches)
function P._find_substring_replacements(file_lines, search_text, replace_text)
    local diff_blocks = {}

    for line_idx, line_content in ipairs(file_lines) do
        if line_content:find(search_text, 1, true) then
            -- Escape pattern for gsub
            local escaped_search =
                search_text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
            -- Replace first occurrence in this line
            -- Use function replacement to ensure literal text (no pattern interpretation)
            local modified_line = line_content:gsub(escaped_search, function()
                return replace_text
            end, 1)

            ---@type agentic.DiffHandler.DiffBlock
            local block = {
                start_line = line_idx,
                end_line = line_idx,
                old_lines = { line_content },
                new_lines = { modified_line },
            }

            table.insert(diff_blocks, block)
        end
    end

    return diff_blocks
end

return M
