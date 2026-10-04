--- Fails a test run when an assertion runs inside a deferred callback.
---
--- mini.test runs each case inside `pcall`. A callback queued with
--- `vim.schedule` or `vim.defer_fn` runs after that `pcall` returned, so a
--- failing assertion there was never reported. `install` marks every callback
--- queued while a case executes; `check` (called by every assertion helper)
--- raises inside a marked callback, and the mark records the failure on the
--- case that queued it, so the run exits non-zero.
--- @class tests.helpers.DeferredGuard
local M = {}

local MiniTest = require("mini.test")

M.MESSAGE =
    "assertion inside a deferred callback (vim.schedule / vim.defer_fn): store the value and assert in the it() body. See tests/AGENTS.md"

local depth = 0

--- @return table|nil case The mini.test case whose hook or body is running
local function executing_case()
    local case = MiniTest.current.case
    local state = case and case.exec and case.exec.state
    if type(state) == "string" and state:find("^Executing") then
        return case
    end
    return nil
end

--- @param fn function
--- @param case table
--- @return function
local function mark(fn, case)
    return function(...)
        depth = depth + 1
        local ok, err = pcall(fn, ...)
        depth = depth - 1
        if not ok then
            if
                depth == 0
                and type(err) == "string"
                and err:find(M.MESSAGE, 1, true)
            then
                table.insert(case.exec.fails, err)
            end
            error(err, 0)
        end
    end
end

function M.check()
    if depth > 0 then
        error(M.MESSAGE, 2)
    end
end

function M.install()
    local schedule = vim.schedule
    local defer_fn = vim.defer_fn

    --- @diagnostic disable-next-line: duplicate-set-field
    vim.schedule = function(fn)
        local case = executing_case()
        return schedule(case and mark(fn, case) or fn)
    end

    --- @diagnostic disable-next-line: duplicate-set-field
    vim.defer_fn = function(fn, timeout)
        local case = executing_case()
        return defer_fn(case and mark(fn, case) or fn, timeout)
    end
end

return M
