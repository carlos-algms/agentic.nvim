--- Pretty-print single-line JSON bodies in tool call output so they
--- read as multi-line blocks in the chat buffer and become foldable.
--- @class agentic.utils.JsonFormat
local M = {}

local INDENT = "  "
local MIN_LENGTH = 80

--- Decide whether a single-line string is worth pretty-printing. Cheap
--- structural check before paying for `vim.json.decode`.
--- @param line string
--- @return boolean
local function looks_like_json(line)
    if #line < MIN_LENGTH then
        return false
    end

    local trimmed = line:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return false
    end

    local first = trimmed:sub(1, 1)
    local last = trimmed:sub(-1)

    if first == "{" and last == "}" then
        return true
    end

    if first == "[" and last == "]" then
        return true
    end

    return false
end

--- Distinguish array-shaped tables from object-shaped tables. Lua has
--- one table type, so we look at the keys: contiguous integer keys
--- starting at 1 means array; anything else means object. Empty tables
--- are treated as arrays (matches `vim.json.decode("[]")` returning `{}`).
--- @param value table
--- @return boolean
local function is_array(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end

    if count == 0 then
        return true
    end

    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end

    return true
end

--- @param value any
--- @param depth integer
--- @param parts string[]
local function encode(value, depth, parts)
    local t = type(value)

    if t == "nil" or value == vim.NIL then
        table.insert(parts, "null")
        return
    end

    if t == "boolean" then
        table.insert(parts, value and "true" or "false")
        return
    end

    if t == "number" then
        table.insert(parts, tostring(value))
        return
    end

    if t == "string" then
        table.insert(parts, vim.json.encode(value))
        return
    end

    if t ~= "table" then
        table.insert(parts, vim.json.encode(value))
        return
    end

    local indent = string.rep(INDENT, depth)
    local inner = string.rep(INDENT, depth + 1)

    if is_array(value) then
        if #value == 0 then
            table.insert(parts, "[]")
            return
        end

        table.insert(parts, "[\n")
        for i, item in ipairs(value) do
            table.insert(parts, inner)
            encode(item, depth + 1, parts)
            if i < #value then
                table.insert(parts, ",")
            end
            table.insert(parts, "\n")
        end
        table.insert(parts, indent)
        table.insert(parts, "]")
        return
    end

    local keys = {}
    for k in pairs(value) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    if #keys == 0 then
        table.insert(parts, "{}")
        return
    end

    table.insert(parts, "{\n")
    for i, k in ipairs(keys) do
        table.insert(parts, inner)
        table.insert(parts, vim.json.encode(tostring(k)))
        table.insert(parts, ": ")
        encode(value[k], depth + 1, parts)
        if i < #keys then
            table.insert(parts, ",")
        end
        table.insert(parts, "\n")
    end
    table.insert(parts, indent)
    table.insert(parts, "}")
end

--- Pretty-print a Lua value back to JSON with 2-space indentation.
--- @param value any
--- @return string
local function pretty(value)
    local parts = {}
    encode(value, 0, parts)
    return table.concat(parts)
end

--- Try to format a single string as pretty-printed JSON. Returns the
--- original string unchanged when it doesn't look like JSON or fails to
--- parse (truncated/streaming JSON, non-standard formats).
--- @param line string
--- @return string formatted
function M.format_line(line)
    if not looks_like_json(line) then
        return line
    end

    local ok, decoded = pcall(
        vim.json.decode,
        line,
        { luanil = { object = true, array = true } }
    )
    if not ok or type(decoded) ~= "table" then
        return line
    end

    return pretty(decoded)
end

--- Format a body (array of buffer lines). Only formats when the body
--- is a single line that parses as JSON. Multi-line bodies and short
--- lines pass through untouched.
---
--- Idempotent: re-running on already-formatted bodies returns the same
--- shape because the pretty-printer is deterministic.
--- @param lines string[]
--- @return string[] formatted
function M.format_lines(lines)
    if type(lines) ~= "table" or #lines ~= 1 then
        return lines
    end

    local formatted = M.format_line(lines[1])
    if formatted == lines[1] then
        return lines
    end

    return vim.split(formatted, "\n")
end

return M
