local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")

-- Real-subprocess tests for ACPTransport. We bypass `tests/helpers/child.lua`
-- because its `setup()` mocks `agentic.acp.acp_transport`; here we need the
-- real module to spawn a real process.
--
-- This is the canonical exception to the "MUST stub `agentic.acp.acp_transport`"
-- rule in `tests/AGENTS.md`: that rule exists for tests that *use* the
-- transport. This file *tests* the transport itself, so spawning a real
-- subprocess is the whole point. No provider binary is spawned; only /bin/sh.

describe("ACPTransport process lifecycle", function()
    local child

    before_each(function()
        child = MiniTest.new_child_neovim()
        child.restart({ "-i", "NONE", "-u", "NONE" })
        child.lua("vim.opt.rtp:prepend(...)", { vim.fn.getcwd() })
    end)

    after_each(function()
        child.stop()
    end)

    --- @param pid integer
    --- @return boolean alive
    local function is_alive(pid)
        vim.fn.system({ "kill", "-0", tostring(pid) })
        return vim.v.shell_error == 0
    end

    --- @param pid integer
    --- @param timeout_ms integer
    --- @return boolean died
    local function wait_for_death(pid, timeout_ms)
        local deadline = vim.uv.hrtime() + timeout_ms * 1e6
        while vim.uv.hrtime() < deadline do
            if not is_alive(pid) then
                return true
            end
            vim.uv.sleep(25)
        end
        return false
    end

    it(
        "kills descendant processes when wrapper does not forward signals",
        function()
            -- Reproduces the codex-acp.js orphan bug: the npm wrapper uses
            -- spawnSync with no signal handlers, so SIGTERM kills the wrapper
            -- but leaves its native child reparented to PID 1.
            --
            -- Wrapper:
            --   1. fork a long-sleeping grandchild
            --   2. emit its PID as a JSON line on stdout
            --   3. `exec cat` so the foreground process holds stdin open
            --      without any signal trap. SIGTERM => cat dies, sleep orphans.
            --
            -- The backgrounded `sleep` is in the same session/pgrp as the
            -- foreground shell because `detached = true` already called
            -- `setsid` at spawn time and `sh -c` does not create a new pgrp
            -- without job control. See ADR 0006.
            local got_pid = child.lua([[
                local Transport = require("agentic.acp.acp_transport")
                _G.t = {}
                _G.transport = Transport.create_stdio_transport({
                    command = "/bin/sh",
                    args = {
                        "-c",
                        'sleep 300 & echo "{\\"pid\\":$!}"; exec cat >/dev/null',
                    },
                }, {
                    on_state_change = function(s) _G.t.state = s end,
                    on_message = function(msg) _G.t.grandchild_pid = msg.pid end,
                    on_reconnect = function() end,
                })
                _G.transport:start()
                return vim.wait(2000, function()
                    return _G.t.grandchild_pid ~= nil
                end)
            ]])

            assert.is_true(got_pid)
            local grandchild_pid = child.lua_get([[_G.t.grandchild_pid]])
            assert.is_not_nil(grandchild_pid)
            assert.is_true(is_alive(grandchild_pid))

            child.lua([[ _G.transport:stop() ]])

            local died = wait_for_death(grandchild_pid, 1500)

            -- Best-effort cleanup if the test failed so we don't leak between
            -- runs.
            if not died then
                vim.fn.system({ "kill", "-9", tostring(grandchild_pid) })
            end

            assert.is_true(died)
        end
    )
end)

describe("ACPTransport.decode_line", function()
    local Transport = require("agentic.acp.acp_transport")

    it("decodes JSON null as nil, not vim.NIL", function()
        local ok, message = Transport.decode_line('{"a":null,"b":[],"c":{}}')
        --- @cast message any

        assert.is_true(ok)
        assert.is_nil(message.a)
        assert.is_table(message.b)
        assert.equal(type(message.c), "table")
    end)

    it("returns false on malformed JSON", function()
        local ok = Transport.decode_line("{not json")

        assert.is_false(ok)
    end)
end)
