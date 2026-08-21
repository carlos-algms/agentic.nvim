local TerminalManager = require("agentic.acp.terminal_manager")
local assert = require("tests.helpers.assert")

--- Wait until `predicate` returns truthy or the timeout elapses, pumping the
--- event loop so vim.system callbacks and their scheduled work can run.
--- @param predicate fun(): any
local function wait_for(predicate)
    vim.wait(2000, predicate, 10)
end

describe("terminal manager", function()
    it("rejects a create request without a command", function()
        local manager = TerminalManager:new()

        local id, err = manager:create({})

        assert.is_nil(id)
        assert.is_not_nil(err)
    end)

    it("runs a command and captures its output and exit status", function()
        local manager = TerminalManager:new()

        local id = manager:create({
            command = "printf",
            args = { "hello" },
        })

        assert.is_not_nil(id)

        wait_for(function()
            local output = manager:get_output(id)
            return output and output.exitStatus ~= nil
        end)

        local output = manager:get_output(id)
        assert.equal(output.output, "hello")
        assert.is_false(output.truncated)
        assert.equal(output.exitStatus.exitCode, 0)
    end)

    it("resolves wait_for_exit once the process exits", function()
        local manager = TerminalManager:new()

        local id = manager:create({ command = "true" })
        assert.is_not_nil(id)

        local status
        local known = manager:wait_for_exit(id, function(s)
            status = s
        end)

        assert.is_true(known)

        wait_for(function()
            return status ~= nil
        end)

        assert.is_not_nil(status)
        assert.equal(status.exitCode, 0)
    end)

    it("reports a non-zero exit code", function()
        local manager = TerminalManager:new()

        local id = manager:create({ command = "false" })

        wait_for(function()
            local output = manager:get_output(id)
            return output and output.exitStatus ~= nil
        end)

        assert.equal(manager:get_output(id).exitStatus.exitCode, 1)
    end)

    it("caps output to outputByteLimit and flags truncation", function()
        local manager = TerminalManager:new()

        local id = manager:create({
            command = "printf",
            args = { "abcdefghij" },
            outputByteLimit = 4,
        })

        wait_for(function()
            local output = manager:get_output(id)
            return output and output.exitStatus ~= nil
        end)

        local output = manager:get_output(id)
        assert.equal(output.output, "ghij")
        assert.is_true(output.truncated)
    end)

    it("returns nil/false for an unknown terminal id", function()
        local manager = TerminalManager:new()

        assert.is_nil(manager:get_output("term_missing"))
        assert.is_false(manager:kill("term_missing"))
        assert.is_false(manager:release("term_missing"))
        assert.is_false(
            manager:wait_for_exit("term_missing", function() end)
        )
    end)

    it("release_session drops only that session's terminals", function()
        local manager = TerminalManager:new()

        local a = manager:create({ command = "true", sessionId = "s1" })
        local b = manager:create({ command = "true", sessionId = "s2" })

        manager:release_session("s1")

        assert.is_nil(manager:get_output(a))
        assert.is_not_nil(manager:get_output(b))
    end)

    it("drops the terminal record on release", function()
        local manager = TerminalManager:new()

        local id = manager:create({ command = "true" })
        wait_for(function()
            local output = manager:get_output(id)
            return output and output.exitStatus ~= nil
        end)

        assert.is_true(manager:release(id))
        assert.is_nil(manager:get_output(id))
    end)
end)
