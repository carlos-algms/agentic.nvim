local assert = require("tests.helpers.assert")
local DeferredGuard = require("tests.helpers.deferred_guard")

--- Runs `fn` on the next loop tick through `schedule_fn` and returns the
--- `pcall` result of `DeferredGuard.check` inside that callback.
--- @param schedule_fn fun(cb: fun())
--- @return boolean|nil ok
--- @return string|nil err
local function check_in_callback(schedule_fn)
    local ok, err
    schedule_fn(function()
        ok, err = pcall(DeferredGuard.check)
    end)
    vim.wait(1000, function()
        return ok ~= nil
    end, 10)
    return ok, err
end

describe("tests.helpers.deferred_guard", function()
    it("rejects a check inside a vim.schedule callback", function()
        local ok, err = check_in_callback(vim.schedule)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("deferred callback", 1, true))
    end)

    it("rejects a check inside a vim.defer_fn callback", function()
        local ok, err = check_in_callback(function(cb)
            vim.defer_fn(cb, 1)
        end)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("deferred callback", 1, true))
    end)

    it("allows a check in the test body", function()
        local ok = pcall(DeferredGuard.check)
        assert.is_true(ok)
    end)

    it("fails the run when an assertion runs in a deferred callback", function()
        local result = vim.system({
            vim.v.progpath,
            "--headless",
            "-i",
            "NONE",
            "-n",
            "-u",
            "tests/init.lua",
            "-c",
            "lua require('tests.runner').run_file('tests/fixtures/deferred_assert.lua')",
        }, { text = true, timeout = 30000 }):wait()

        local output = (result.stdout or "") .. (result.stderr or "")
        assert.is_not.equal(result.code, 0)
        assert.truthy(output:find("deferred callback", 1, true))
    end)
end)
