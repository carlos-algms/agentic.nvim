local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionStarter", function()
    local SessionStarter
    local schedule_stub
    local get_instance_stub
    local queue

    local NOOP_HANDLERS = {
        on_session_update = function() end,
        on_request_permission = function() end,
        on_error = function() end,
        on_tool_call = function() end,
        on_tool_call_update = function() end,
    }

    --- @param handlers agentic.acp.ClientHandlers
    --- @return fun(): agentic.acp.ClientHandlers prepare_handlers
    local function prepare(handlers)
        return function()
            return handlers
        end
    end

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
        local AgentInstance = require("agentic.acp.agent_instance")
        get_instance_stub = spy.stub(AgentInstance, "get_instance")
        SessionStarter = require("agentic.session_starter")
    end)

    after_each(function()
        get_instance_stub:revert()
        schedule_stub:revert()
    end)

    it("returns an attempt without sending before readiness", function()
        local agent = new_agent()
        local attempt = SessionStarter.start(
            agent,
            { kind = "new" },
            prepare(NOOP_HANDLERS),
            function() end
        )

        assert.is_not_nil(attempt)
        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
        assert.spy(get_instance_stub).was.called(0)
    end)

    for _, case in ipairs({
        { kind = "new", expected_id = "new-id" },
        { kind = "load", session_id = "load-id", expected_id = "load-id" },
    }) do
        it("waits for readiness and starts only " .. case.kind, function()
            local agent = new_agent()
            local result

            SessionStarter.start(
                agent,
                case,
                prepare(NOOP_HANDLERS),
                function(value)
                    result = value
                end
            )

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
                local adopted

                local attempt = SessionStarter.start(
                    agent,
                    {
                        kind = case.kind,
                        session_id = case.kind == "load" and case.session_id
                            or nil,
                    },
                    prepare(NOOP_HANDLERS),
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

                attempt:cancel()
                drain()

                assert.is_nil(adopted)
                assert.equal(1, #agent.cancelled)
                assert.equal(case.session_id, agent.cancelled[1])
            end
        )
    end

    it("cancels before readiness without sending a request", function()
        local agent = new_agent()
        local callback_count = 0
        local received_err

        local attempt = SessionStarter.start(
            agent,
            { kind = "new" },
            prepare(NOOP_HANDLERS),
            function(_, err)
                callback_count = callback_count + 1
                received_err = err
            end
        )
        attempt:cancel()
        attempt:cancel()
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
                local adopted

                local attempt = SessionStarter.start(
                    agent,
                    {
                        kind = case.kind,
                        session_id = case.kind == "load" and case.session_id
                            or nil,
                    },
                    prepare(NOOP_HANDLERS),
                    function(result)
                        adopted = result
                    end
                )
                agent.ready_callback(agent)
                attempt:cancel()

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
        local callback_count = 0
        local received_err

        SessionStarter.start(
            agent,
            { kind = "new" },
            prepare(NOOP_HANDLERS),
            function(_, err)
                callback_count = callback_count + 1
                received_err = err
            end
        )
        agent.failure_callback({ code = -32000, message = "failed" })
        agent.failure_callback({ code = -32000, message = "again" })
        drain()

        assert.equal(1, callback_count)
        assert.equal("failed", received_err.message)
    end)

    it("completes request failure once", function()
        local agent = new_agent()
        local callback_count = 0
        local received_err

        SessionStarter.start(
            agent,
            { kind = "new" },
            prepare(NOOP_HANDLERS),
            function(_, err)
                callback_count = callback_count + 1
                received_err = err
            end
        )
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
        local received_err

        local attempt = SessionStarter.start(
            agent,
            { kind = "load", session_id = "failed-load" },
            prepare(NOOP_HANDLERS),
            function(_, err)
                received_err = err
            end
        )
        agent.ready_callback(agent)
        agent.load_callback(nil, { code = -32001, message = "load failed" })

        attempt:cancel()
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
        local order = {}
        local handlers = vim.deepcopy(NOOP_HANDLERS)
        local attempt
        --- @type fun(): boolean
        local is_replaying
        handlers.on_session_update = function()
            assert.is_true(is_replaying())
            order[#order + 1] = "replay"
        end

        attempt = SessionStarter.start(
            agent,
            { kind = "load", session_id = "load-id" },
            function(replay_predicate)
                is_replaying = replay_predicate
                return handlers
            end,
            function()
                order[#order + 1] = "complete"
            end
        )
        agent.ready_callback(agent)

        assert.is_true(attempt:has_session_id("load-id"))
        drain()
        assert.same({ "replay", "complete" }, order)
        assert.is_false(attempt:is_replaying())
    end)

    it("keeps starter state independent", function()
        local first_agent = new_agent()
        local second_agent = new_agent()

        local first = SessionStarter.start(
            first_agent,
            { kind = "load", session_id = "one" },
            prepare(NOOP_HANDLERS),
            function() end
        )
        local second = SessionStarter.start(
            second_agent,
            { kind = "load", session_id = "two" },
            prepare(NOOP_HANDLERS),
            function() end
        )

        assert.is_true(first:has_session_id("one"))
        assert.is_false(first:has_session_id("two"))
        assert.is_true(second:has_session_id("two"))
    end)

    it("rejects an invalid start specification without sending", function()
        local agent = new_agent()
        local callback = spy.new()
        local invalid_spec = { kind = "invalid" }

        SessionStarter.start(
            agent,
            invalid_spec --[[@as agentic.SessionStartSpec]],
            prepare(NOOP_HANDLERS),
            callback
        )
        drain()

        assert.spy(callback).was.called(1)
        assert.is_nil(callback.calls[1][1])
        assert.equal(-32602, callback.calls[1][2].code)
        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
    end)

    it("rejects missing handlers without waiting for readiness", function()
        local agent = new_agent()
        local callback = spy.new()
        local expected_err = { code = -32000, message = "no handlers" }

        SessionStarter.start(agent, { kind = "new" }, function()
            return nil, expected_err
        end, callback)
        drain()

        assert.spy(callback).was.called(1)
        assert.is_nil(callback.calls[1][1])
        assert.equal(expected_err, callback.calls[1][2])
        assert.equal(0, agent.create_calls)
        assert.equal(0, agent.load_calls)
        assert.is_nil(agent.ready_callback)
    end)
end)
