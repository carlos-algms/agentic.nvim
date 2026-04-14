-- Plain text reporter for mini.test (no ANSI colors)
-- Wraps MiniTest.gen_reporter.stdout, intercepting io.stdout to strip
-- ANSI escape codes for non-interactive terminals and CI.
local M = {}

local ANSI_PATTERN = "\27%[[%d;]*m"

--- @param opts { group_depth?: number, quit_on_finish?: boolean }|nil
--- @return table reporter
function M.new(opts)
    local MiniTest = require("mini.test")
    local real_stdout = io.stdout

    local proxy = setmetatable({}, {
        __index = real_stdout,
    })

    function proxy:write(text)
        return real_stdout:write((text:gsub(ANSI_PATTERN, "")))
    end

    rawset(io, "stdout", proxy)

    local inner = MiniTest.gen_reporter.stdout(opts or {})
    local inner_finish = inner.finish

    --- @type table
    local reporter = {
        start = inner.start,
        update = inner.update,
        finish = function()
            local ok, err = pcall(inner_finish)
            rawset(io, "stdout", real_stdout)
            if not ok then
                error(err)
            end
        end,
    }

    return reporter
end

return M
