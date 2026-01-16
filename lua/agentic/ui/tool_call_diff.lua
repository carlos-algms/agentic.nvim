--- @class agentic.ui.ToolCallDiff.DiffBlock
--- @field start_line integer
--- @field end_line integer
--- @field old_lines string[]
--- @field new_lines string[]

--- @class agentic.ui.ToolCallDiff.ChangedPair
--- @field old_idx integer|nil Original index in old_lines (nil if pure insertion)
--- @field new_idx integer|nil Original index in new_lines (nil if pure deletion)
--- @field old_line string|nil Old line content
--- @field new_line string|nil New line content

--- @class agentic.ui.ToolCallDiff.FilteredLines
--- @field old_lines string[] Filtered old lines (only changed)
--- @field new_lines string[] Filtered new lines (only changed)
--- @field pairs agentic.ui.ToolCallDiff.ChangedPair[] Paired changed lines with indices

--- @class agentic.ui.ToolCallDiff.ExtractOpts
--- @field path string
--- @field new_text string|string[]
--- @field old_text? string|string[]
--- @field replace_all? boolean
--- @field strict? boolean When true, don't return fallback blocks if match fails

--- @class agentic.ui.ToolCallDiff
local M = {}

local TextMatcher = require("agentic.utils.text_matcher")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

-- vim.diff was renamed to vim.text.diff (identical signature, just namespace move)
-- Fallback needed for backward compatibility with Neovim < 0.12
--- @type fun(a: string, b: string, opts: table): integer[][]
--- @diagnostic disable-next-line: deprecated
local diff_fn = vim.text and vim.text.diff or vim.diff

--- @param lines string[]
--- @return boolean
local function is_empty_lines(lines)
    return #lines == 0 or (#lines == 1 and lines[1] == "")
end

--- @param opts agentic.ui.ToolCallDiff.ExtractOpts
--- @return agentic.ui.ToolCallDiff.DiffBlock[] diff_blocks
function M.extract_diff_blocks(opts)
    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local diff_blocks = {}

    if not opts.path or opts.path == "" or not opts.new_text then
        return diff_blocks
    end

    local old_lines = M._normalize_text_to_lines(opts.old_text)
    local new_lines = M._normalize_text_to_lines(opts.new_text)

    local abs_path = FileSystem.to_absolute_path(opts.path)
    local file_lines = FileSystem.read_from_buffer_or_disk(abs_path) or {}

    -- When old_text is nil/empty but file exists, treat as full file replacement
    if is_empty_lines(old_lines) and #file_lines > 0 then
        old_lines = file_lines
    end

    if is_empty_lines(old_lines) then
        table.insert(diff_blocks, M._create_new_file_diff_block(new_lines))
    else
        local blocks =
            M._match_or_substring_fallback(file_lines, old_lines, new_lines)

        if blocks then
            if opts.replace_all then
                vim.list_extend(diff_blocks, blocks)
            else
                -- Only use the first match if replace_all is false
                table.insert(diff_blocks, blocks[1])
            end
        elseif not opts.strict then
            Logger.debug("[ACP diff] Failed to locate diff", opts.path)
            -- Fallback: display the diff even if we can't match it
            table.insert(diff_blocks, {
                start_line = 1,
                end_line = math.max(1, #old_lines),
                old_lines = old_lines,
                new_lines = new_lines,
            })
        end
    end

    return M.minimize_diff_blocks(diff_blocks)
end

--- Convert a hunk to a minimized diff block
--- @param diff_block agentic.ui.ToolCallDiff.DiffBlock
--- @param hunk integer[]
--- @return agentic.ui.ToolCallDiff.DiffBlock
local function hunk_to_block(diff_block, hunk)
    local start_a, count_a, start_b, count_b = unpack(hunk)

    --- @type number|nil
    local start_line
    --- @type number|nil
    local end_line
    --- @type string[]|nil
    local old_lines
    --- @type string[]|nil
    local new_lines

    if count_a > 0 then
        local end_a = math.min(start_a + count_a - 1, #diff_block.old_lines)
        old_lines = vim.list_slice(diff_block.old_lines, start_a, end_a)
        start_line = diff_block.start_line + start_a - 1
        end_line = start_line + count_a - 1
    else
        -- Pure insertion: position before which to insert
        old_lines = {}
        start_line = diff_block.start_line + start_a
        end_line = start_line - 1
    end

    if count_b > 0 then
        local end_b = math.min(start_b + count_b - 1, #diff_block.new_lines)
        new_lines = vim.list_slice(diff_block.new_lines, start_b, end_b)
    else
        new_lines = {}
    end

    --- @type agentic.ui.ToolCallDiff.DiffBlock
    local result = {
        start_line = start_line,
        end_line = end_line,
        old_lines = old_lines,
        new_lines = new_lines,
    }

    return result
end

--- Minimize diff blocks by removing unchanged lines using vim.diff
--- @param diff_blocks agentic.ui.ToolCallDiff.DiffBlock[]
--- @return agentic.ui.ToolCallDiff.DiffBlock[]
function M.minimize_diff_blocks(diff_blocks)
    --- @type agentic.ui.ToolCallDiff.DiffBlock[]
    local minimized = {}

    for _, diff_block in ipairs(diff_blocks) do
        local old_string = table.concat(diff_block.old_lines, "\n")
        local new_string = table.concat(diff_block.new_lines, "\n")

        -- Skip unchanged blocks
        if old_string == new_string then
            goto continue_block
        end

        -- Fast path for single-line blocks
        if #diff_block.old_lines == 1 and #diff_block.new_lines == 1 then
            table.insert(minimized, diff_block)
            goto continue_block
        end

        local patch = diff_fn(old_string, new_string, {
            algorithm = "histogram",
            result_type = "indices",
            ctxlen = 0,
        })

        if #patch > 0 then
            for _, hunk in ipairs(patch) do
                table.insert(minimized, hunk_to_block(diff_block, hunk))
            end
        else
            -- Edge case: vim.diff returns empty patch but strings differ
            table.insert(minimized, diff_block)
        end

        ::continue_block::
    end

    table.sort(minimized, function(a, b)
        return a.start_line < b.start_line
    end)

    return minimized
end

--- Create a diff block for a new file
--- @param new_lines string[]
--- @return agentic.ui.ToolCallDiff.DiffBlock
function M._create_new_file_diff_block(new_lines)
    return {
        start_line = 1,
        end_line = math.max(1, #new_lines),
        old_lines = {},
        new_lines = new_lines,
    }
end

--- Add a deletion pair to the result
--- @param result agentic.ui.ToolCallDiff.FilteredLines
--- @param old_idx integer
--- @param old_line string
local function add_deletion(result, old_idx, old_line)
    table.insert(result.old_lines, old_line)
    table.insert(result.pairs, {
        old_idx = old_idx,
        new_idx = nil,
        old_line = old_line,
        new_line = nil,
    })
end

--- Add an insertion pair to the result
--- @param result agentic.ui.ToolCallDiff.FilteredLines
--- @param new_idx integer
--- @param new_line string
local function add_insertion(result, new_idx, new_line)
    table.insert(result.new_lines, new_line)
    table.insert(result.pairs, {
        old_idx = nil,
        new_idx = new_idx,
        old_line = nil,
        new_line = new_line,
    })
end

--- Add a modification pair to the result
--- @param result agentic.ui.ToolCallDiff.FilteredLines
--- @param old_idx integer
--- @param new_idx integer
--- @param old_line string
--- @param new_line string
local function add_modification(result, old_idx, new_idx, old_line, new_line)
    table.insert(result.old_lines, old_line)
    table.insert(result.new_lines, new_line)
    table.insert(result.pairs, {
        old_idx = old_idx,
        new_idx = new_idx,
        old_line = old_line,
        new_line = new_line,
    })
end

--- Filter unchanged lines from old/new arrays, returning only changed pairs
--- @param old_lines string[]
--- @param new_lines string[]
--- @return agentic.ui.ToolCallDiff.FilteredLines
function M.filter_unchanged_lines(old_lines, new_lines)
    --- @type agentic.ui.ToolCallDiff.FilteredLines
    local result = { old_lines = {}, new_lines = {}, pairs = {} }

    local old_string = table.concat(old_lines, "\n")
    local new_string = table.concat(new_lines, "\n")

    if old_string == new_string then
        return result
    end

    local patch = diff_fn(old_string, new_string, {
        algorithm = "histogram",
        result_type = "indices",
        ctxlen = 0,
    })

    for _, hunk in ipairs(patch) do
        local start_a, count_a, start_b, count_b = unpack(hunk)
        local pair_count = math.min(count_a, count_b)

        -- Paired modifications: only include if lines differ
        for i = 0, pair_count - 1 do
            local old_line = old_lines[start_a + i]
            local new_line = new_lines[start_b + i]
            if old_line ~= new_line then
                add_modification(
                    result,
                    start_a + i,
                    start_b + i,
                    old_line,
                    new_line
                )
            end
        end

        -- Remaining deletions (old lines without corresponding new lines)
        for i = pair_count, count_a - 1 do
            add_deletion(result, start_a + i, old_lines[start_a + i])
        end

        -- Remaining insertions (new lines without corresponding old lines)
        for i = pair_count, count_b - 1 do
            add_insertion(result, start_b + i, new_lines[start_b + i])
        end
    end

    return result
end

--- Normalize text to lines array, handling nil and vim.NIL
--- @param text? string|string[]
--- @return string[]
function M._normalize_text_to_lines(text)
    if not text or text == "" or text == vim.NIL then
        return {}
    end

    if type(text) == "string" then
        return vim.split(text, "\n")
    end

    return text
end

--- Try fuzzy match for all occurrences, fallback to substring replacement for single-line cases
--- @param file_lines string[] File content lines
--- @param old_lines string[] Old text lines
--- @param new_lines string[] New text lines
--- @return agentic.ui.ToolCallDiff.DiffBlock[]|nil blocks Array of diff blocks or nil if no match
function M._match_or_substring_fallback(file_lines, old_lines, new_lines)
    local matches = TextMatcher.find_all_matches(file_lines, old_lines)

    if #matches > 0 then
        return vim.tbl_map(function(match)
            return {
                start_line = match.start_line,
                end_line = match.end_line,
                old_lines = old_lines,
                new_lines = new_lines,
            }
        end, matches)
    end

    -- Fallback to substring replacement for single-line cases
    if #old_lines == 1 and #new_lines == 1 then
        local blocks = M._find_substring_replacements(
            file_lines,
            old_lines[1],
            new_lines[1]
        )
        return #blocks > 0 and blocks or nil
    end

    return nil
end

--- Find all substring replacement occurrences in file lines
--- @param file_lines string[] File content lines
--- @param search_text string Text to search for
--- @param replace_text string Text to replace with
--- @return agentic.ui.ToolCallDiff.DiffBlock[] diff_blocks Array of diff blocks (empty if no matches)
function M._find_substring_replacements(file_lines, search_text, replace_text)
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

            --- @type agentic.ui.ToolCallDiff.DiffBlock
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
