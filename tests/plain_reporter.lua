-- Plain text reporter for mini.test (no ANSI colors)
-- Wraps MiniTest.gen_reporter.stdout, intercepting io.stdout to strip
-- ANSI escape codes for non-interactive terminals and CI.
local M = {}

local ANSI_PATTERN = "\27%[[%d;]*m"

--- @param opts { group_depth?: number, quit_on_finish?: boolean }|nil
--- @return table reporter
function M.new(opts)
    local MiniTest = require("mini.test")
    local inner = MiniTest.gen_reporter.stdout(opts or {})
    local real_stdout = io.stdout

    local proxy = setmetatable({}, {
        __index = real_stdout,
    })

    function proxy:write(text)
        return real_stdout:write(text:gsub(ANSI_PATTERN, ""))
    end

    --- @return table reporter
    local reporter = {}

    reporter.start = function(cases)
        rawset(io, "stdout", proxy)
        inner.start(cases)
    end

    reporter.update = function(case_num)
        inner.update(case_num)
    end

    reporter.finish = function()
        inner.finish()
        rawset(io, "stdout", real_stdout)
    end

    return reporter
end

return M
