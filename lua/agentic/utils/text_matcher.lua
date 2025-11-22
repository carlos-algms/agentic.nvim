---@class agentic.utils.TextMatcher
local M = {}

---@param str string The string to trim
---@param opts {prefix: string?, suffix: string?}? Optional table with prefix and/or suffix to remove
---@return string trimmed
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

---@param original_lines string[]
---@param target_lines string[]
---@param i integer Starting position
---@param compare_fn function
---@return boolean matches
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

function M.try_find_match(original_lines, target_lines, compare_fn)
    if
        #original_lines == 0
        or #target_lines == 0
        or #target_lines > #original_lines
    then
        return nil, nil
    end

    for i = 1, #original_lines - #target_lines + 1 do
        if matches_at_position(original_lines, target_lines, i, compare_fn) then
            return i, i + #target_lines - 1
        end
    end
    return nil, nil
end

---Find all matches using compare function
---@param original_lines string[]
---@param target_lines string[]
---@param compare_fn fun(line_a: string, line_b: string): boolean
---@return table[] matches Array of {start_line, end_line} pairs
function M.try_find_all_matches(original_lines, target_lines, compare_fn)
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

---Find all matches with fuzzy matching
---@param original_lines string[]
---@param target_lines string[]
---@return table[] matches Array of {start_line, end_line} pairs, empty if no matches
function M.find_all_matches(original_lines, target_lines)
    for _, strategy in ipairs(MATCH_STRATEGIES) do
        local matches =
            M.try_find_all_matches(original_lines, target_lines, strategy)
        if #matches > 0 then
            return matches
        end
    end
    return {}
end

return M
