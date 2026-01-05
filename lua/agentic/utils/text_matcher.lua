--- @class agentic.utils.TextMatcher
local M = {}

--- @class agentic.utils.TextMatcher.Match
--- @field start_line integer
--- @field end_line integer

--- Find all exact matches of target_lines within original_lines
--- @param original_lines string[]
--- @param target_lines string[]
--- @return agentic.utils.TextMatcher.Match[] matches
function M.find_all_matches(original_lines, target_lines)
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
        if M._matches_at_position(original_lines, target_lines, i) then
            table.insert(matches, {
                start_line = i,
                end_line = i + #target_lines - 1,
            })
            -- Skip past match to avoid overlapping
            i = i + #target_lines
        else
            i = i + 1
        end
    end

    return matches
end

--- Check if target_lines match at position i in original_lines
--- @param original_lines string[]
--- @param target_lines string[]
--- @param i integer Starting position (1-indexed)
--- @return boolean
function M._matches_at_position(original_lines, target_lines, i)
    for j = 1, #target_lines do
        if original_lines[i + j - 1] ~= target_lines[j] then
            return false
        end
    end

    return true
end

return M
