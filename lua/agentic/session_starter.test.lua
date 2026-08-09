local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionStarter", function()
    local SessionStarter
    local schedule_stub
    local queue

    local NOOP_HANDLERS = {
        on_session_update = function() end,
        on_request_permission = function() end,
        on_error = function() end,
        on_tool_call = function() end,
        on_tool_call_update = function() end,
    }

    local function drain()
        while #queue > 0 do
            local fn = table.remove(queue, 1)
            fn()
        end
    end

    local function new_agent()
        local agent = {
            provider_config = { name = "Test" },
            ready_callback = nil,
            failure_callback = nil,
            create_callback = nil,
            load_callback = nil,
            create_calls = 0,
            load_calls = 0,
            cancelled = {},
        }

        function agent:when_ready(on_ready, on_failure)
            self.ready_callback = on_ready
            self.failure_callback = on_failure
        end

        function agent:create_session(_handlers, callback)
            self.create_calls = self.create_calls + 1
            self.create_callback = callback
        end

        function agent:load_session(
            session_id,
            _cwd,
            _servers,
            _handlers,
            callback
        )
            self.load_calls = self.load_calls + 1
            self.load_session_id = session_id
            self.load_callback = callback
        end

        function agent:cancel_session(session_id)
            self.cancelled[#self.cancelled + 1] = session_id
        end

        return agent
    end

    before_each(function()
        queue = {}
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            queue[#queue + 1] = fn
        end)
        SessionStarter = require("agentic.session_starter")
    end)

    after_each(function()
        schedule_stub:revert()
    end)

    it("constructs without sending a request", function()
        local agent = new_agent()
        local AgentInstance = require("agentic.acp.agent_instance")
        local get_instance_stub = spy.stub(AgentInstance, "get_instance")
        local starter = SessionStarter:new(agent)

        assert.is_not_nil(starter)
        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
        assert.spy(get_instance_stub).was.called(0)
        get_instance_stub:revert()
    end)

    for _, case in ipairs({
        { kind = "new", expected_id = "new-id" },
        { kind = "load", session_id = "load-id", expected_id = "load-id" },
    }) do
        it("waits for readiness and starts only " .. case.kind, function()
            local agent = new_agent()
            local starter = SessionStarter:new(agent)
            local result

            starter:start(case, NOOP_HANDLERS, function(value)
                result = value
            end)

            assert.equal(0, agent.create_calls)
            assert.equal(0, agent.load_calls)
            agent.ready_callback(agent)

            if case.kind == "new" then
                assert.equal(1, agent.create_calls)
                assert.equal(0, agent.load_calls)
                agent.create_callback({ sessionId = "new-id" }, nil)
            else
                assert.equal(0, agent.create_calls)
                assert.equal(1, agent.load_calls)
                agent.load_callback({}, nil)
            end

            assert.is_nil(result)
            drain()
            assert.equal(case.kind, result.kind)
            assert.equal(case.expected_id, result.session_id)
        end)
    end

    for _, case in ipairs({
        { kind = "new", session_id = "queued-new" },
        { kind = "load", session_id = "queued-load" },
    }) do
        it(
            "cancels queued " .. case.kind .. " success before adoption",
            function()
                local agent = new_agent()
                local starter = SessionStarter:new(agent)
                local adopted

                starter:start(
                    {
                        kind = case.kind,
                        session_id = case.kind == "load" and case.session_id
                            or nil,
                    },
                    NOOP_HANDLERS,
                    function(result)
                        adopted = result
                    end
                )
                agent.ready_callback(agent)
                if case.kind == "new" then
                    agent.create_callback({ sessionId = case.session_id }, nil)
                else
                    agent.load_callback({}, nil)
                end

                starter:cancel()
                drain()

                assert.is_nil(adopted)
                assert.equal(1, #agent.cancelled)
                assert.equal(case.session_id, agent.cancelled[1])
            end
        )
    end

    it("rejects a second start", function()
        local agent = new_agent()
        local starter = SessionStarter:new(agent)
        local second_err

        starter:start({ kind = "new" }, NOOP_HANDLERS, function() end)
        starter:start({ kind = "new" }, NOOP_HANDLERS, function(_, err)
            second_err = err
        end)

        drain()
        assert.is_not_nil(second_err)
        assert.equal(0, agent.create_calls)
    end)

    it("cancels before readiness without sending a request", function()
        local agent = new_agent()
        local starter = SessionStarter:new(agent)
        local callback_count = 0
        local received_err

        starter:start({ kind = "new" }, NOOP_HANDLERS, function(_, err)
            callback_count = callback_count + 1
            received_err = err
        end)
        starter:cancel()
        starter:cancel()
        agent.ready_callback(agent)
        drain()

        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
        assert.equal(1, callback_count)
        assert.is_not_nil(received_err)
    end)

    for _, case in ipairs({
        { kind = "new", session_id = "late-new" },
        { kind = "load", session_id = "late-load" },
    }) do
        it(
            "cancels a late " .. case.kind .. " result without adopting it",
            function()
                local agent = new_agent()
                local starter = SessionStarter:new(agent)
                local adopted

                starter:start(
                    {
                        kind = case.kind,
                        session_id = case.kind == "load" and case.session_id
                            or nil,
                    },
                    NOOP_HANDLERS,
                    function(result)
                        adopted = result
                    end
                )
                agent.ready_callback(agent)
                starter:cancel()

                if case.kind == "new" then
                    assert.equal(1, agent.create_calls)
                    agent.create_callback({ sessionId = case.session_id }, nil)
                else
                    assert.equal(1, agent.load_calls)
                    agent.load_callback({}, nil)
                end
                drain()

                assert.is_nil(adopted)
                assert.equal(1, #agent.cancelled)
                assert.equal(case.session_id, agent.cancelled[1])
            end
        )
    end

    it("completes readiness and request failures once", function()
        local agent = new_agent()
        local starter = SessionStarter:new(agent)
        local callback_count = 0
        local received_err

        starter:start({ kind = "new" }, NOOP_HANDLERS, function(_, err)
            callback_count = callback_count + 1
            received_err = err
        end)
        agent.failure_callback({ code = -32000, message = "failed" })
        agent.failure_callback({ code = -32000, message = "again" })
        drain()

        assert.equal(1, callback_count)
        assert.equal("failed", received_err.message)
    end)

    it("completes request failure once", function()
        local agent = new_agent()
        local starter = SessionStarter:new(agent)
        local callback_count = 0
        local received_err

        starter:start({ kind = "new" }, NOOP_HANDLERS, function(_, err)
            callback_count = callback_count + 1
            received_err = err
        end)
        agent.ready_callback(agent)
        agent.create_callback(
            nil,
            { code = -32001, message = "request failed" }
        )
        drain()

        assert.equal(1, callback_count)
        assert.equal("request failed", received_err.message)
    end)

    it("does not cancel a load whose failure is awaiting delivery", function()
        local agent = new_agent()
        local starter = SessionStarter:new(agent)
        local received_err

        starter:start(
            { kind = "load", session_id = "failed-load" },
            NOOP_HANDLERS,
            function(_, err)
                received_err = err
            end
        )
        agent.ready_callback(agent)
        agent.load_callback(nil, { code = -32001, message = "load failed" })

        starter:cancel()
        drain()

        assert.is_not_nil(received_err)
        assert.equal(0, #agent.cancelled)
    end)

    it("finishes load after queued replay updates", function()
        local agent = new_agent()
        function agent:load_session(
            _session_id,
            _cwd,
            _servers,
            handlers,
            callback
        )
            self.load_calls = self.load_calls + 1
            vim.schedule(function()
                handlers.on_session_update({
                    sessionUpdate = "user_message_chunk",
                })
            end)
            callback({}, nil)
        end
        local starter = SessionStarter:new(agent)
        local order = {}
        local handlers = vim.deepcopy(NOOP_HANDLERS)
        handlers.on_session_update = function()
            assert.is_true(starter:is_replaying())
            order[#order + 1] = "replay"
        end

        starter:start(
            { kind = "load", session_id = "load-id" },
            handlers,
            function()
                order[#order + 1] = "complete"
            end
        )
        agent.ready_callback(agent)

        assert.is_true(starter:has_session_id("load-id"))
        drain()
        assert.same({ "replay", "complete" }, order)
        assert.is_false(starter:is_replaying())
    end)

    it("keeps starter state independent", function()
        local first_agent = new_agent()
        local second_agent = new_agent()
        local first = SessionStarter:new(first_agent)
        local second = SessionStarter:new(second_agent)

        first:start(
            { kind = "load", session_id = "one" },
            NOOP_HANDLERS,
            function() end
        )
        second:start(
            { kind = "load", session_id = "two" },
            NOOP_HANDLERS,
            function() end
        )

        assert.is_true(first:has_session_id("one"))
        assert.is_false(first:has_session_id("two"))
        assert.is_true(second:has_session_id("two"))
    end)
end)
