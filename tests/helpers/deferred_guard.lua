--- Fails a test run when an assertion runs inside a deferred callback.
---
--- mini.test runs each case inside `pcall`. A callback queued with
--- `vim.schedule` or `vim.defer_fn` runs after that `pcall` returned, so a
--- failing assertion there was never reported. `install` marks every callback
--- queued while a case executes, or while a marked callback runs; `check`
--- (called by every `MiniTest.expect` function) raises inside a marked
--- callback, and the mark records the failure on the case that queued it, so
--- the run exits non-zero. The reporter waits for `pending()` to reach zero
--- before it prints, so a marked `vim.schedule` callback that a later callback
--- queued still reports. `vim.defer_fn` timers are not counted: a stopped timer
--- never fires, and waiting for it would stall every run.
--- @class tests.helpers.DeferredGuard
local M = {}

local MiniTest = require("mini.test")

M.MESSAGE =
    "assertion inside a deferred callback (vim.schedule / vim.defer_fn): store the value and assert in the it() body. See tests/AGENTS.md"

local depth = 0

--- Marked `vim.schedule` callbacks queued and not run yet
local pending = 0

--- @type table|nil Case that queued the marked callback now running
local running_case = nil

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
--- @param counted boolean Whether `pending` tracks this callback
--- @return function
local function mark(fn, case, counted)
    if counted then
        pending = pending + 1
    end
    return function(...)
        if counted then
            counted = false
            pending = pending - 1
        end
        depth = depth + 1
        local outer_case = running_case
        running_case = case
        local ok, err = pcall(fn, ...)
        running_case = outer_case
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

--- @return integer count Marked `vim.schedule` callbacks not run yet
function M.pending()
    return pending
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
        local case = running_case or executing_case()
        return schedule(case and mark(fn, case, true) or fn)
    end

    --- @diagnostic disable-next-line: duplicate-set-field
    vim.defer_fn = function(fn, timeout)
        local case = running_case or executing_case()
        return defer_fn(case and mark(fn, case, false) or fn, timeout)
    end

    for name, expect_fn in pairs(MiniTest.expect) do
        if type(expect_fn) == "function" then
            MiniTest.expect[name] = function(...)
                M.check()
                return expect_fn(...)
            end
        end
    end
end

return M
