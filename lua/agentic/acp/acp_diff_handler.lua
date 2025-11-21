local P = {}

---@class agentic.acp.ACPDiffHandler
local M = {}

local TextMatcher = require("agentic.utils.text_matcher")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

---Check if tool call contains diff content
---@param tool_call agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@return boolean has_diff
function M.has_diff_content(tool_call)
    for _, content_item in ipairs(tool_call.content or {}) do
        if content_item.type == "diff" then
            return true
        end
    end

    local raw = tool_call.rawInput
    if not raw then
        return false
    end

    local has_new = (raw.new_string ~= nil and raw.new_string ~= vim.NIL)
    return has_new
end

---Extract diff blocks from ACP tool call content
---@param tool_call table Must have `content` (array) and optionally `rawInput` fields
---@return table<string, DiffBlock[]> diff_blocks_by_file Maps file path to list of diff blocks
function M.extract_diff_blocks(tool_call)
    ---@type table<string, DiffBlock[]>
    local diff_blocks_by_file = {}

    local raw = tool_call.rawInput
    local should_use_raw_input = raw and raw.replace_all == true

    if not should_use_raw_input then
        for _, content_item in ipairs(tool_call.content or {}) do
            if content_item.type == "diff" then
                local path = content_item.path
                local oldText = content_item.oldText
                local newText = content_item.newText

                if oldText == "" or oldText == vim.NIL or oldText == nil then
                    local new_lines = P._normalize_text_to_lines(newText)
                    P._add_diff_block(diff_blocks_by_file, path, P._create_new_file_diff_block(new_lines))
                else
                    local old_lines = P._normalize_text_to_lines(oldText)
                    local new_lines = P._normalize_text_to_lines(newText)

                    local abs_path = FileSystem.to_absolute_path(path)
                    local file_lines = FileSystem.read_from_buffer_or_disk(abs_path) or {}

                    local blocks = P._match_or_substring_fallback(file_lines, old_lines, new_lines, false)
                    if blocks then
                        for _, block in ipairs(blocks) do
                            P._add_diff_block(diff_blocks_by_file, path, block)
                        end
                    else
                        Logger.debug("[ACP diff content] Failed to locate diff", { path = path })
                    end
                end
            end
        end
    end

    if raw and (should_use_raw_input or P._is_table_empty(diff_blocks_by_file)) then

        local file_path = raw.file_path
        local old_string = raw.old_string == vim.NIL and nil or raw.old_string
        local new_string = raw.new_string == vim.NIL and nil or raw.new_string

        if file_path and new_string then
            local old_lines = P._normalize_text_to_lines(old_string)
            local new_lines = P._normalize_text_to_lines(new_string)
            local abs_path = FileSystem.to_absolute_path(file_path)
            local file_lines = FileSystem.read_from_buffer_or_disk(abs_path) or {}

            if #old_lines == 0 or (#old_lines == 1 and old_lines[1] == "") then
                diff_blocks_by_file[file_path] = { P._create_new_file_diff_block(new_lines) }
            else
                local replace_all = raw.replace_all

                if replace_all then
                    if #old_lines == 1 and #new_lines == 1 then
                        local found_blocks = P._find_substring_replacements(file_lines, old_lines[1], new_lines[1], true)
                        if #found_blocks > 0 then
                            diff_blocks_by_file[file_path] = found_blocks
                        else
                            Logger.debug("[ACP diff rawInput] [replace_all] No matches", { file_path = file_path })
                        end
                    else
                        local matches = TextMatcher.find_all_matches(file_lines, old_lines)
                        if #matches > 0 then
                            diff_blocks_by_file[file_path] = {}
                            for _, match in ipairs(matches) do
                                P._add_diff_block(diff_blocks_by_file, file_path, {
                                    start_line = match.start_line,
                                    end_line = match.end_line,
                                    old_lines = old_lines,
                                    new_lines = new_lines,
                                })
                            end
                        else
                            Logger.debug("[ACP diff rawInput] [replace_all] No matches", { file_path = file_path })
                        end
                    end
                else
                    local blocks = P._match_or_substring_fallback(file_lines, old_lines, new_lines, false)
                    if blocks then
                        diff_blocks_by_file[file_path] = blocks
                    else
                        Logger.debug("[ACP diff rawInput] Failed to locate diff", { file_path = file_path })
                    end
                end
            end
        end
    end

    for path, diff_blocks in pairs(diff_blocks_by_file) do
        table.sort(diff_blocks, function(a, b) return a.start_line < b.start_line end)
        diff_blocks_by_file[path] = P.minimize_diff_blocks(diff_blocks)
    end

    return diff_blocks_by_file
end

---Minimize diff blocks by removing unchanged lines using vim.diff
---@param diff_blocks DiffBlock[]
---@return DiffBlock[]
function P.minimize_diff_blocks(diff_blocks)
    local minimized = {}
    for _, diff_block in ipairs(diff_blocks) do
        local old_string = table.concat(diff_block.old_lines, "\n")
        local new_string = table.concat(diff_block.new_lines, "\n")

        ---@type integer[][]
        ---@diagnostic disable-next-line: assign-type-mismatch
        local patch = vim.diff(old_string, new_string, {
            algorithm = "histogram",
            result_type = "indices",
            ctxlen = 0,
        })

        if #patch > 0 then
            for _, hunk in ipairs(patch) do
                local start_a, count_a, start_b, count_b = unpack(hunk)
                local minimized_block = {}
                if count_a > 0 then
                    local end_a = math.min(start_a + count_a - 1, #diff_block.old_lines)
                    minimized_block.old_lines = vim.list_slice(diff_block.old_lines, start_a, end_a)
                else
                    minimized_block.old_lines = {}
                end
                if count_b > 0 then
                    local end_b = math.min(start_b + count_b - 1, #diff_block.new_lines)
                    minimized_block.new_lines = vim.list_slice(diff_block.new_lines, start_b, end_b)
                else
                    minimized_block.new_lines = {}
                end
                if count_a > 0 then
                    minimized_block.start_line = diff_block.start_line + start_a - 1
                    minimized_block.end_line = minimized_block.start_line + count_a - 1
                else
                    -- For insertions, start_line is the position before which to insert
                    minimized_block.start_line = diff_block.start_line + start_a
                    minimized_block.end_line = minimized_block.start_line - 1
                end
                table.insert(minimized, minimized_block)
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
---@return DiffBlock
function P._create_new_file_diff_block(new_lines)
    return {
        start_line = 1,
        end_line = 0,
        old_lines = {},
        new_lines = new_lines,
    }
end

---Normalize text to lines array, handling nil and vim.NIL
---@param text string|nil
---@return string[]
function P._normalize_text_to_lines(text)
    if not text or text == vim.NIL or text == "" then
        return {}
    end
    return type(text) == "string" and vim.split(text, "\n") or {}
end

---Add a diff block to the collection, ensuring the path array exists
---@param diff_blocks_by_file table<string, DiffBlock[]>
---@param path string
---@param diff_block DiffBlock
function P._add_diff_block(diff_blocks_by_file, path, diff_block)
    diff_blocks_by_file[path] = diff_blocks_by_file[path] or {}
    table.insert(diff_blocks_by_file[path], diff_block)
end

---Find and replace substring occurrences in file lines
---@param file_lines string[] File content lines
---@param search_text string Text to search for
---@param replace_text string Text to replace with
---@param replace_all boolean If true, replace all occurrences; if false, only first match
---@return DiffBlock[] Array of diff blocks created
function P._find_substring_replacements(file_lines, search_text, replace_text, replace_all)
    local diff_blocks = {}
    local escaped_search = search_text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")

    for line_idx, line_content in ipairs(file_lines) do
        if line_content:find(search_text, 1, true) then
            local modified_line
            if replace_all then
                -- Replace all occurrences in this line
                -- Use function replacement to avoid pattern interpretation of replace_text
                -- This ensures literal replacement (e.g., "result%1" stays as "result%1", not backreference)
                modified_line = line_content:gsub(escaped_search, function()
                    return replace_text
                end)
            else
                -- Replace first occurrence only
                -- Use function replacement to ensure literal text (no pattern interpretation)
                modified_line = line_content:gsub(escaped_search, function()
                    return replace_text
                end, 1)
            end

            table.insert(diff_blocks, {
                start_line = line_idx,
                end_line = line_idx,
                old_lines = { line_content },
                new_lines = { modified_line },
            })

            -- For single replacement mode, stop after first match
            if not replace_all then
                break
            end
        end
    end

    return diff_blocks
end

function P._is_table_empty(tbl)
    return next(tbl) == nil
end

---Try fuzzy match, fallback to substring replacement for single-line cases
---@param file_lines string[] File content lines
---@param old_lines string[] Old text lines
---@param new_lines string[] New text lines
---@param replace_all boolean If true, replace all occurrences
---@return DiffBlock[]|nil blocks Array of diff blocks or nil if no match
function P._match_or_substring_fallback(file_lines, old_lines, new_lines, replace_all)
    local start_line, end_line = TextMatcher.fuzzy_match(file_lines, old_lines)

    if start_line and end_line then
        return {{
            start_line = start_line,
            end_line = end_line,
            old_lines = old_lines,
            new_lines = new_lines,
        }}
    end

    if #old_lines == 1 and #new_lines == 1 then
        local blocks = P._find_substring_replacements(file_lines, old_lines[1], new_lines[1], replace_all)
        return #blocks > 0 and blocks or nil
    end

    return nil
end

---@class DiffBlock
---@field start_line integer
---@field end_line integer
---@field old_lines string[]
---@field new_lines string[]

return M
