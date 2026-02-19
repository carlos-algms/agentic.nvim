--- @class agentic.utils.TextMatcher
local M = {}

--- @param str string The string to trim
--- @param opts { prefix?: string, suffix?: string }|nil Optional table with prefix and/or suffix to remove
--- @return string trimmed
local function trim(str, opts)
    local res = str

    if not opts then
        return res
    end

    if opts.suffix then
        -- Check length first to avoid invalid string index
        if #res >= #opts.suffix then
            if res:sub(#res - #opts.suffix + 1) == opts.suffix then
                res = res:sub(1, #res - #opts.suffix)
            end
        end
    end

    if opts.prefix then
        if res:sub(1, #opts.prefix) == opts.prefix then
            res = res:sub(#opts.prefix + 1)
        end
    end

    return res
end

local function trim_space(text)
    return text and text:gsub("%s+", "") or text
end

--- @param original_lines string[]
--- @param target_lines string[]
--- @param i integer Starting position
--- @param compare_fn function
--- @return boolean matches
local function matches_at_position(original_lines, target_lines, i, compare_fn)
    -- Validate bounds
    if i < 1 or i + #target_lines - 1 > #original_lines then
        return false
    end

    for j = 1, #target_lines do
        local idx = i + j - 1

        if idx < 1 or idx > #original_lines then
            return false
        end

        if not compare_fn(original_lines[idx], target_lines[j]) then
            return false
        end
    end

    return true
end

local MATCH_STRATEGIES = {
    function(a, b)
        return a == b
    end,

    function(a, b)
        return trim(a, { suffix = " \t" }) == trim(b, { suffix = " \t" })
    end,

    function(a, b)
        return trim_space(a) == trim_space(b)
    end,
}

--- Find all matches with fuzzy matching
--- @param original_lines string[]
--- @param target_lines string[]
--- @return table[] matches Array of {start_line, end_line} pairs, empty if no matches
function M.find_all_matches(original_lines, target_lines)
    for _, strategy in ipairs(MATCH_STRATEGIES) do
        local matches =
            M._try_find_all_matches(original_lines, target_lines, strategy)

        if #matches > 0 then
            return matches
        end
    end

    return {}
end

--- Find all matches using compare function
--- @param original_lines string[]
--- @param target_lines string[]
--- @param compare_fn fun(line_a: string, line_b: string): boolean
--- @return table[] matches Array of {start_line, end_line} pairs
function M._try_find_all_matches(original_lines, target_lines, compare_fn)
    local matches = {}

    if
        #original_lines == 0
        or #target_lines == 0
        or #target_lines > #original_lines
    then
        return matches
    end

    local i = 1

    while i <= #original_lines - #target_lines + 1 do
        if matches_at_position(original_lines, target_lines, i, compare_fn) then
            local end_line = i + #target_lines - 1
            table.insert(matches, { start_line = i, end_line = end_line })
            -- Skip past the match to avoid infinite loop
            i = end_line + 1
        else
            i = i + 1
        end
    end

    return matches
end

--- @class agentic.utils.TextMatcher.PrefixMatch
--- @field start_line integer
--- @field end_line integer
--- @field suffix string Remaining text from file line after prefix match on last line

--- Prefix-aware strategies: each returns {compare_fn, starts_with_fn}
--- compare_fn is used for lines 1..N-1 (full match)
--- starts_with_fn checks if file line starts with target line (last line only)
local PREFIX_STRATEGIES = {
    {
        compare = function(a, b)
            return a == b
        end,
        starts_with = function(file_line, target_line)
            return file_line:sub(1, #target_line) == target_line
        end,
    },
    {
        compare = function(a, b)
            return trim(a, { suffix = " \t" }) == trim(b, { suffix = " \t" })
        end,
        starts_with = function(file_line, target_line)
            local trimmed_file = trim(file_line, { suffix = " \t" })
            local trimmed_target = trim(target_line, { suffix = " \t" })
            return trimmed_file:sub(1, #trimmed_target) == trimmed_target
        end,
    },
    {
        compare = function(a, b)
            return trim_space(a) == trim_space(b)
        end,
        starts_with = function(file_line, target_line)
            local stripped_file = trim_space(file_line)
            local stripped_target = trim_space(target_line)
            return stripped_file:sub(1, #stripped_target) == stripped_target
        end,
    },
}

--- Find all matches allowing the last target line to be a prefix of the file line.
--- Used as fallback when exact matching fails due to ACP sending partial boundary lines.
--- @param original_lines string[]
--- @param target_lines string[]
--- @return agentic.utils.TextMatcher.PrefixMatch[] matches
function M.find_all_prefix_boundary_matches(original_lines, target_lines)
    if #target_lines < 2 then
        return {}
    end

    for _, strategy in ipairs(PREFIX_STRATEGIES) do
        local matches = M._try_find_prefix_boundary_matches(
            original_lines,
            target_lines,
            strategy.compare,
            strategy.starts_with
        )

        if #matches > 0 then
            return matches
        end
    end

    return {}
end

--- @param original_lines string[]
--- @param target_lines string[]
--- @param compare_fn fun(a: string, b: string): boolean
--- @param starts_with_fn fun(file_line: string, target_line: string): boolean
--- @return agentic.utils.TextMatcher.PrefixMatch[]
function M._try_find_prefix_boundary_matches(
    original_lines,
    target_lines,
    compare_fn,
    starts_with_fn
)
    --- @type agentic.utils.TextMatcher.PrefixMatch[]
    local matches = {}

    if
        #original_lines == 0
        or #target_lines < 2
        or #target_lines > #original_lines
    then
        return matches
    end

    local head_lines = vim.list_slice(target_lines, 1, #target_lines - 1)
    local last_target = target_lines[#target_lines]

    local i = 1
    while i <= #original_lines - #target_lines + 1 do
        if matches_at_position(original_lines, head_lines, i, compare_fn) then
            local last_idx = i + #target_lines - 1
            local file_line = original_lines[last_idx]

            if starts_with_fn(file_line, last_target) then
                local suffix = file_line:sub(#last_target + 1)
                table.insert(matches, {
                    start_line = i,
                    end_line = last_idx,
                    suffix = suffix,
                })
                i = last_idx + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    return matches
end

return M
