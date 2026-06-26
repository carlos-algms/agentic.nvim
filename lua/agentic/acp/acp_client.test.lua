--- @diagnostic disable: invisible, duplicate-set-field
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")
local spy = require("tests.helpers.spy")

describe("ACPClient", function()
    --- @type agentic.acp.ACPClient
    local ACPClient

    --- @type TestStub
    local transport_send_stub
    --- @type TestStub
    local transport_start_stub
    --- @type TestStub
    local transport_stop_stub

    --- @type TestStub
    local create_transport_stub

    --- @type TestStub
    local logger_debug_stub
    --- @type TestStub
    local logger_debug_to_file_stub
    --- @type TestStub
    local logger_notify_stub

    local mock_transport

    --- Reverted in `after_each`: an assertion throwing mid-test must not leave
    --- `vim.schedule` stubbed for every later file.
    --- @type TestStub|nil
    local schedule_stub

    --- @type fun(state: agentic.acp.ClientConnectionState)|nil
    local captured_on_state_change

    --- @type fun(message: agentic.acp.ResponseRaw)|nil
    local captured_on_message

    --- @type agentic.acp.InitializeParams|nil
    local captured_initialize_params

    local PROMPT_CAPS =
        { image = false, audio = false, embeddedContext = false }

    local LIST_CAPS = {
        loadSession = true,
        promptCapabilities = PROMPT_CAPS,
        sessionCapabilities = { list = true },
    }

    local LOAD_CAPS = {
        loadSession = true,
        promptCapabilities = PROMPT_CAPS,
    }

    --- @type agentic.acp.ClientHandlers
    local NOOP_HANDLERS = {
        on_session_update = function() end,
        on_request_permission = function() end,
        on_error = function() end,
        on_tool_call = function() end,
        on_tool_call_update = function() end,
    }

    --- @param agent_caps agentic.acp.AgentCapabilities|nil
    --- @return agentic.acp.ACPClient client
    local function create_ready_client(agent_caps)
        create_transport_stub:invokes(function(_config, callbacks)
            captured_on_state_change = callbacks.on_state_change
            captured_on_message = callbacks.on_message
            return mock_transport
        end)

        transport_start_stub:invokes(function()
            if captured_on_state_change then
                captured_on_state_change("connected")
            end
        end)

        transport_send_stub:invokes(function(_self, data)
            local decoded = vim.json.decode(data)
            if decoded.method == "initialize" and captured_on_message then
                captured_initialize_params = decoded.params
                captured_on_message({
                    jsonrpc = "2.0",
                    method = "initialize",
                    id = decoded.id,
                    result = {
                        protocolVersion = 1,
                        agentCapabilities = agent_caps,
                        agentInfo = { name = "test" },
                    },
                })
            end
        end)

        local client = ACPClient:new({ command = "test-agent" }, function() end)

        transport_send_stub:reset()
        transport_send_stub:invokes(function() end)

        return client
    end

    --- @param _client agentic.acp.ACPClient
    --- @param method string
    --- @param response_result table|nil
    --- @param response_err agentic.acp.ACPError|nil
    local function stub_send_response(
        _client,
        method,
        response_result,
        response_err
    )
        transport_send_stub:invokes(function(_self, data)
            local decoded = vim.json.decode(data)
            if decoded.method == method and captured_on_message then
                captured_on_message({
                    jsonrpc = "2.0",
                    id = decoded.id,
                    result = response_result,
                    error = response_err,
                })
            end
        end)
    end

    --- Queues `vim.schedule` callbacks so a test can drop the subscriber
    --- between scheduling and running, as `cancel_session` does when a session
    --- is destroyed mid-stream. The stub is reverted in `after_each`.
    --- @return fun()[] queue
    local function queue_schedules()
        --- @type fun()[]
        local queue = {}
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            queue[#queue + 1] = fn
        end)

        return queue
    end

    --- @param queue fun()[]
    local function drain(queue)
        for _, fn in ipairs(queue) do
            fn()
        end
    end

    --- @return table[] sent decoded JSON-RPC frames
    local function capture_sent()
        --- @type table[]
        local sent = {}
        transport_send_stub:invokes(function(_self, data)
            sent[#sent + 1] = vim.json.decode(data)
        end)

        return sent
    end

    before_each(function()
        package.loaded["agentic.acp.acp_client"] = nil
        package.loaded["agentic.acp.acp_transport"] = nil
        captured_initialize_params = nil

        local Logger = require("agentic.utils.logger")
        logger_debug_stub = spy.stub(Logger, "debug")
        logger_debug_to_file_stub = spy.stub(Logger, "debug_to_file")
        logger_notify_stub = spy.stub(Logger, "notify")

        mock_transport = {
            send = function() end,
            start = function() end,
            stop = function() end,
        }
        transport_send_stub = spy.stub(mock_transport, "send")
        transport_start_stub = spy.stub(mock_transport, "start")
        transport_stop_stub = spy.stub(mock_transport, "stop")

        local transport_module = require("agentic.acp.acp_transport")
        create_transport_stub =
            spy.stub(transport_module, "create_stdio_transport")
        create_transport_stub:returns(mock_transport)

        ACPClient = require("agentic.acp.acp_client")
    end)

    after_each(function()
        if schedule_stub then
            schedule_stub:revert()
            schedule_stub = nil
        end

        logger_debug_stub:revert()
        logger_debug_to_file_stub:revert()
        logger_notify_stub:revert()
        transport_send_stub:revert()
        transport_start_stub:revert()
        transport_stop_stub:revert()
        create_transport_stub:revert()
    end)

    describe("initialize", function()
        it("advertises boolean session config options as an object", function()
            assert.equal("[]", vim.json.encode({}))
            create_ready_client()

            assert.is_not_nil(captured_initialize_params)
            --- @cast captured_initialize_params agentic.acp.InitializeParams
            assert.is_not_nil(
                captured_initialize_params.clientCapabilities.session
            )

            local config_options =
                captured_initialize_params.clientCapabilities.session.configOptions
            assert.is_not_nil(config_options)
            --- @cast config_options agentic.acp.SessionConfigOptionsCapabilities
            assert.is_not_nil(config_options.boolean)

            local encoded = vim.json.encode(captured_initialize_params)
            assert.is_not_nil(encoded:find('"boolean":{}', 1, true))
        end)
    end)

    describe("mock response delivery", function()
        local child = Child.new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("delivers responses synchronously by default", function()
            child.lua([[
                local ACPClient = require("agentic.acp.acp_client")
                local client = ACPClient:new({ command = "test-agent" }, function() end)
                local callback_called = false

                _G.p5_direct_delivery = {}

                client:create_session({
                    on_session_update = function() end,
                    on_request_permission = function() end,
                    on_error = function() end,
                    on_tool_call = function() end,
                    on_tool_call_update = function() end,
                }, function(result, err)
                    callback_called = true
                    _G.p5_direct_delivery.callback_fast = vim.in_fast_event()
                    _G.p5_direct_delivery.result = result
                    _G.p5_direct_delivery.err = err
                end)

                client.transport:deliver({
                    jsonrpc = "2.0",
                    id = client.id_counter,
                    result = { sessionId = "direct-session" },
                })

                _G.p5_direct_delivery.completed_before_return = callback_called
            ]])

            local result = child.lua_get("_G.p5_direct_delivery")
            assert.is_true(result.completed_before_return)
            assert.is_false(result.callback_fast)
            assert.equal("direct-session", result.result.sessionId)
            assert.is_nil(result.err)
        end)

        it("delivers ACP errors from a libuv fast event", function()
            child.lua([[
                local ACPClient = require("agentic.acp.acp_client")
                local client = ACPClient:new({ command = "test-agent" }, function() end)

                _G.p5_fast_delivery = { messages = {}, callbacks = {} }

                local original_on_message = client.transport.callbacks.on_message
                client.transport.callbacks.on_message = function(message)
                    local delivered = {
                        fast = vim.in_fast_event(),
                    }
                    local ok, err = pcall(original_on_message, message)
                    delivered.ok = ok
                    delivered.err = err
                    _G.p5_fast_delivery.messages[#_G.p5_fast_delivery.messages + 1] = delivered
                end

                local handlers = {
                    on_session_update = function() end,
                    on_request_permission = function() end,
                    on_error = function() end,
                    on_tool_call = function() end,
                    on_tool_call_update = function() end,
                }

                local function create_request(index)
                    client:create_session(handlers, function(result, err)
                        _G.p5_fast_delivery.callbacks[index] = {
                            fast = vim.in_fast_event(),
                            result = result,
                            err = err,
                        }
                    end)
                    return client.id_counter
                end

                local first_id = create_request(1)
                local second_id = create_request(2)

                local first_timer = client.transport:deliver({
                    jsonrpc = "2.0",
                    id = first_id,
                    error = { code = -32000, message = "first fast delivery failed" },
                }, "fast_event")
                local second_timer = client.transport:deliver({
                    jsonrpc = "2.0",
                    id = second_id,
                    error = { code = -32001, message = "second fast delivery failed" },
                }, "fast_event")

                _G.p5_fast_timers = { first_timer, second_timer }
                _G.p5_fast_delivery.distinct_timers = first_timer ~= second_timer
            ]])

            vim.uv.sleep(50)
            child.api.nvim_eval("1")
            child.lua([[
                _G.p5_fast_delivery.first_timer_closed =
                    _G.p5_fast_timers[1]:is_closing()
                _G.p5_fast_delivery.second_timer_closed =
                    _G.p5_fast_timers[2]:is_closing()
            ]])

            local result = child.lua_get("_G.p5_fast_delivery")
            assert.is_true(result.distinct_timers)
            assert.is_true(result.first_timer_closed)
            assert.is_true(result.second_timer_closed)
            assert.equal(2, #result.messages)
            assert.equal(2, #result.callbacks)

            for _, delivered in ipairs(result.messages) do
                assert.is_true(delivered.fast)
                assert.is_true(delivered.ok)
                assert.is_nil(delivered.err)
            end

            assert.is_true(result.callbacks[1].fast)
            assert.is_nil(result.callbacks[1].result)
            assert.equal(-32000, result.callbacks[1].err.code)
            assert.equal(
                "first fast delivery failed",
                result.callbacks[1].err.message
            )
            assert.is_true(result.callbacks[2].fast)
            assert.is_nil(result.callbacks[2].result)
            assert.equal(-32001, result.callbacks[2].err.code)
            assert.equal(
                "second fast delivery failed",
                result.callbacks[2].err.message
            )
        end)
    end)

    describe("list_sessions", function()
        it("sends session/list request", function()
            local client = create_ready_client(LIST_CAPS)

            client:list_sessions("/tmp", function() end)
            assert.spy(transport_send_stub).was.called(1)

            local sent_data = transport_send_stub.calls[1][2]
            local decoded = vim.json.decode(sent_data)
            assert.equal("session/list", decoded.method)
            assert.equal("/tmp", decoded.params.cwd)
        end)

        it("callback receives SessionListResponse on success", function()
            local client = create_ready_client(LIST_CAPS)

            --- @type agentic.acp.SessionListResponse|nil
            local received_result
            --- @type agentic.acp.ACPError|nil
            local received_err

            stub_send_response(client, "session/list", {
                sessions = {
                    { sessionId = "s1", cwd = "/tmp", title = "Session 1" },
                },
            }, nil)

            client:list_sessions("/tmp", function(result, err)
                received_result = result
                received_err = err
            end)

            assert.is_not_nil(received_result)
            assert.is_nil(received_err)
            --- @cast received_result agentic.acp.SessionListResponse
            assert.equal(1, #received_result.sessions)
            assert.equal("s1", received_result.sessions[1].sessionId)
        end)

        it("callback receives error on failure", function()
            local client = create_ready_client(LIST_CAPS)

            --- @type agentic.acp.SessionListResponse|nil
            local received_result
            --- @type agentic.acp.ACPError|nil
            local received_err

            stub_send_response(
                client,
                "session/list",
                nil,
                { code = -32000, message = "Transport error" }
            )

            client:list_sessions("/tmp", function(result, err)
                received_result = result
                received_err = err
            end)

            assert.is_nil(received_result)
            assert.is_not_nil(received_err)
            --- @cast received_err agentic.acp.ACPError
            assert.equal(-32000, received_err.code)
            assert.equal("Transport error", received_err.message)
        end)
    end)

    describe("load_session", function()
        it("calls on_load_complete with nil err on success", function()
            local client = create_ready_client(LOAD_CAPS)
            local complete_called = false
            local received_err

            stub_send_response(client, "session/load", {}, nil)

            client:load_session(
                "sid-1",
                "/tmp",
                {},
                NOOP_HANDLERS,
                function(err)
                    complete_called = true
                    received_err = err
                end
            )

            assert.is_true(complete_called)
            assert.is_nil(received_err)
        end)

        it("propagates error to on_load_complete", function()
            local client = create_ready_client(LOAD_CAPS)
            local received_err

            stub_send_response(
                client,
                "session/load",
                nil,
                { code = -32000, message = "load failed" }
            )

            client:load_session(
                "sid-1",
                "/tmp",
                {},
                NOOP_HANDLERS,
                function(err)
                    received_err = err
                end
            )

            assert.is_not_nil(received_err)
            assert.equal(-32000, received_err.code)
            assert.equal("load failed", received_err.message)
        end)

        it(
            "keeps a replacement subscriber after an older load fails",
            function()
                local client = create_ready_client(LOAD_CAPS)
                local request_ids = {}
                transport_send_stub:invokes(function(_self, data)
                    local decoded = vim.json.decode(data)
                    request_ids[#request_ids + 1] = decoded.id
                end)
                --- @type agentic.acp.ClientHandlers
                local first_handlers = vim.deepcopy(NOOP_HANDLERS)
                --- @type agentic.acp.ClientHandlers
                local replacement_handlers = vim.deepcopy(NOOP_HANDLERS)

                client:load_session("sid-1", "/tmp", {}, first_handlers)
                client:load_session("sid-1", "/tmp", {}, replacement_handlers)

                local on_message = captured_on_message
                assert.is_not_nil(on_message)
                --- @cast on_message -nil
                on_message({
                    jsonrpc = "2.0",
                    id = request_ids[1],
                    error = { code = -32000, message = "load failed" },
                })

                assert.is_true(
                    client.subscribers["sid-1"] == replacement_handlers
                )
            end
        )

        it("works without on_load_complete (backward compatible)", function()
            local client = create_ready_client(LOAD_CAPS)

            stub_send_response(client, "session/load", {}, nil)

            assert.has_no_errors(function()
                client:load_session("sid-1", "/tmp", {}, NOOP_HANDLERS)
            end)
        end)
    end)

    describe("set_config_option", function()
        it("sends select values without a type", function()
            local client = create_ready_client()
            --- @diagnostic disable-next-line: invisible
            local send_request_stub = spy.stub(client, "_send_request")

            client:set_config_option({
                sessionId = "s1",
                configId = "model",
                value = "opus",
            }, function() end)

            local params = send_request_stub.calls[1][3]
            assert.equal(
                "session/set_config_option",
                send_request_stub.calls[1][2]
            )
            assert.same({
                sessionId = "s1",
                configId = "model",
                value = "opus",
            }, params)
            assert.is_nil(params.type)
        end)

        it("sends boolean true with the boolean type", function()
            local client = create_ready_client()
            --- @diagnostic disable-next-line: invisible
            local send_request_stub = spy.stub(client, "_send_request")

            client:set_config_option({
                sessionId = "s1",
                configId = "fast",
                type = "boolean",
                value = true,
            }, function() end)

            assert.equal(
                "session/set_config_option",
                send_request_stub.calls[1][2]
            )
            assert.same({
                sessionId = "s1",
                configId = "fast",
                type = "boolean",
                value = true,
            }, send_request_stub.calls[1][3])
        end)

        it("sends boolean false with the boolean type", function()
            local client = create_ready_client()
            --- @diagnostic disable-next-line: invisible
            local send_request_stub = spy.stub(client, "_send_request")

            client:set_config_option({
                sessionId = "s1",
                configId = "fast",
                type = "boolean",
                value = false,
            }, function() end)

            local params = send_request_stub.calls[1][3]
            assert.equal(
                "session/set_config_option",
                send_request_stub.calls[1][2]
            )
            assert.is_false(params.value)
            assert.equal("boolean", params.type)
        end)
    end)

    describe("_drain_pending_callbacks", function()
        local original_schedule = vim.schedule

        before_each(function()
            -- Drain uses vim.schedule to avoid fast-event errors;
            -- run synchronously in tests so assertions work
            --- @diagnostic disable-next-line: duplicate-set-field
            vim.schedule = function(fn)
                fn()
            end
        end)

        after_each(function()
            vim.schedule = original_schedule
        end)

        it("calls pending callbacks with error when disconnected", function()
            local client = create_ready_client()

            -- Register a pending callback via send_prompt (transport stub is a noop)
            --- @type table|nil
            local received_result
            --- @type agentic.acp.ACPError|nil
            local received_err
            local callback_called = false

            client:send_prompt("sid-1", {}, function(result, err)
                callback_called = true
                received_result = result
                received_err = err
            end)

            -- Callback should NOT have been called yet (transport is a noop stub)
            assert.is_false(callback_called)

            -- Simulate disconnect via the on_state_change callback
            assert.is_not_nil(captured_on_state_change)
            --- @cast captured_on_state_change fun(state: agentic.acp.ClientConnectionState)
            captured_on_state_change("disconnected")

            -- Callback should now have been called with error
            assert.is_true(callback_called)
            assert.is_nil(received_result)
            assert.is_not_nil(received_err)
            --- @cast received_err agentic.acp.ACPError
            assert.equal(
                ACPClient.ERROR_CODES.TRANSPORT_ERROR,
                received_err.code
            )
            assert.equal("disconnected", received_err.message)
        end)

        it("calls pending callbacks with error on error state", function()
            local client = create_ready_client()

            local callback_called = false
            --- @type agentic.acp.ACPError|nil
            local received_err

            client:send_prompt("sid-1", {}, function(_result, err)
                callback_called = true
                received_err = err
            end)

            assert.is_false(callback_called)

            assert.is_not_nil(captured_on_state_change)
            --- @cast captured_on_state_change fun(state: agentic.acp.ClientConnectionState)
            captured_on_state_change("error")

            assert.is_true(callback_called)
            assert.is_not_nil(received_err)
            --- @cast received_err agentic.acp.ACPError
            assert.equal(
                ACPClient.ERROR_CODES.TRANSPORT_ERROR,
                received_err.code
            )
            assert.equal("error", received_err.message)
        end)

        it("does not drain callbacks on normal state transitions", function()
            local client = create_ready_client()

            local callback_called = false

            client:send_prompt("sid-1", {}, function()
                callback_called = true
            end)

            assert.is_false(callback_called)

            -- Transition to "ready" should NOT drain callbacks
            assert.is_not_nil(captured_on_state_change)
            --- @cast captured_on_state_change fun(state: agentic.acp.ClientConnectionState)
            captured_on_state_change("ready")
            vim.uv.sleep(10) -- flush any potential vim.schedule

            assert.is_false(callback_called)
        end)

        it("drains multiple pending callbacks", function()
            local client = create_ready_client()

            local calls = { false, false, false }

            client:send_prompt("sid-1", {}, function()
                calls[1] = true
            end)
            client:send_prompt("sid-1", {}, function()
                calls[2] = true
            end)
            client:send_prompt("sid-1", {}, function()
                calls[3] = true
            end)

            assert.is_not_nil(captured_on_state_change)
            --- @cast captured_on_state_change fun(state: agentic.acp.ClientConnectionState)
            captured_on_state_change("disconnected")

            assert.is_true(calls[1])
            assert.is_true(calls[2])
            assert.is_true(calls[3])

            -- callbacks table should be empty after drain
            assert.equal(0, vim.tbl_count(client.callbacks))
        end)
    end)

    describe("__with_subscriber", function()
        it("delivers to a subscriber that is still registered", function()
            local client = create_ready_client()
            local queue = queue_schedules()
            local received = spy.new(function() end)

            client.subscribers["s1"] = NOOP_HANDLERS
            --- @diagnostic disable-next-line: invisible
            client:__with_subscriber("s1", function(sub)
                received(sub)
            end)

            drain(queue)

            assert.spy(received).was.called(1)
            assert.equal(NOOP_HANDLERS, received.calls[1][1])
        end)

        it("skips a subscriber dropped before the callback runs", function()
            local client = create_ready_client()
            local queue = queue_schedules()
            local received = spy.new(function() end)

            client.subscribers["s1"] = NOOP_HANDLERS
            --- @diagnostic disable-next-line: invisible
            client:__with_subscriber("s1", function(sub)
                received(sub)
            end)

            -- `cancel_session` drops the subscriber while the update is queued
            client.subscribers["s1"] = nil

            drain(queue)

            assert.spy(received).was.called(0)
        end)

        it("logs when a subscriber replaces an existing one", function()
            local client = create_ready_client()

            --- @type agentic.acp.ClientHandlers
            local replacement = {
                on_session_update = function() end,
                on_request_permission = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
            }

            logger_debug_stub:reset()

            --- @diagnostic disable-next-line: invisible
            client:_subscribe("s1", NOOP_HANDLERS)
            assert.spy(logger_debug_stub).was.called(0)

            --- @diagnostic disable-next-line: invisible
            client:_subscribe("s1", replacement)

            assert.spy(logger_debug_stub).was.called(1)
            assert.truthy(
                logger_debug_stub.calls[1][1]:match(
                    "Replacing existing subscriber"
                )
            )

            -- Re-subscribing the SAME handlers is a no-op, not a collision
            --- @diagnostic disable-next-line: invisible
            client:_subscribe("s1", replacement)
            assert.spy(logger_debug_stub).was.called(1)
        end)
    end)

    describe("__handle_request_permission", function()
        local REQUEST = {
            sessionId = "s1",
            toolCall = { toolCallId = "tc-1", kind = "edit" },
            options = {
                {
                    optionId = "allow_once",
                    name = "Allow",
                    kind = "allow_once",
                },
            },
        }

        -- `on_missing` EARLY return, distinct from the deferred drop below: no
        -- subscriber when the request arrives, so `__with_subscriber` never
        -- schedules. Unanswered, the JSON-RPC request hangs the subprocess every
        -- other session shares.
        it(
            "answers cancelled when no subscriber was ever registered",
            function()
                local client = create_ready_client()
                local sent = capture_sent()
                local queue = queue_schedules()

                assert.is_nil(client.subscribers["s1"])

                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(13, REQUEST)

                -- Answered synchronously: nothing was queued to drain.
                assert.equal(0, #queue)

                assert.equal(1, #sent)
                assert.equal(13, sent[1].id)
                assert.same(
                    { outcome = { outcome = "cancelled" } },
                    sent[1].result
                )
            end
        )

        it("answers cancelled when the subscriber is gone", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            client.subscribers["s1"] = NOOP_HANDLERS
            --- @diagnostic disable-next-line: invisible
            client:__handle_request_permission(7, REQUEST)

            -- `cancel_session` drops the subscriber while the request is queued.
            -- A response is still owed: the subprocess is shared across every
            -- session.
            client.subscribers["s1"] = nil

            drain(queue)

            assert.equal(1, #sent)
            assert.equal(7, sent[1].id)
            assert.same({ outcome = { outcome = "cancelled" } }, sent[1].result)
        end)

        it(
            "answers cancelled when the handler resolves with no option",
            function()
                local client = create_ready_client()
                local sent = capture_sent()
                local queue = queue_schedules()

                --- @type agentic.acp.ClientHandlers
                local handlers = {
                    on_session_update = function() end,
                    on_error = function() end,
                    on_tool_call = function() end,
                    on_tool_call_update = function() end,
                    -- `PermissionManager:clear` resolves pending requests with a
                    -- nil option on teardown.
                    on_request_permission = function(_request, callback)
                        callback(nil)
                    end,
                }

                client.subscribers["s1"] = handlers
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(9, REQUEST)

                drain(queue)

                assert.equal(1, #sent)
                assert.same(
                    { outcome = { outcome = "cancelled" } },
                    sent[1].result
                )
            end
        )

        -- A malformed request still carries a JSON-RPC `id`. Throwing left it
        -- unanswered AND threw through the transport read loop, hanging the
        -- subprocess every other session shares.
        it("answers cancelled when the request is invalid", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            -- `pcall` result is asserted: a handler that answers cancelled and
            -- THEN throws still breaks the caller, so the throw must fail the
            -- test loudly with its message rather than be swallowed.
            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible, missing-fields
                client:__handle_request_permission(15, { sessionId = "s1" })
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            -- Answered synchronously: no subscriber lookup happens at all.
            assert.equal(0, #queue)

            assert.equal(1, #sent)
            assert.equal(15, sent[1].id)
            assert.same({ outcome = { outcome = "cancelled" } }, sent[1].result)
        end)

        -- `_handle_message` dispatches on `method` alone and forwards
        -- `message.params` unchecked, so a frame with no `params` reaches the
        -- handler with a nil request. Indexing it threw through the transport
        -- read loop and left the `id` unanswered.
        it("answers cancelled when the request payload is missing", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            -- `pcall` result is asserted: a handler that answers cancelled and
            -- THEN throws still breaks the caller, so the throw must fail the
            -- test loudly with its message rather than be swallowed.
            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(17, nil)
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            -- Answered synchronously: no subscriber lookup happens at all.
            assert.equal(0, #queue)

            assert.equal(1, #sent)
            assert.equal(17, sent[1].id)
            assert.same({ outcome = { outcome = "cancelled" } }, sent[1].result)
        end)

        -- A truthy non-table `toolCall` passes a `not request.toolCall` guard.
        -- `__build_tool_call_message` then indexes it inside the scheduled
        -- subscriber dispatch: a number throws ("attempt to index a number
        -- value"), leaving the JSON-RPC `id` unanswered. A string would only
        -- yield a junk-but-harmless message, so the number is the shape that
        -- genuinely fails.
        it("answers cancelled when the tool call is malformed", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            local asked = spy.new(function() end)

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function(request, callback)
                    asked(request, callback)
                end,
            }

            client.subscribers["s1"] = handlers

            --- @type agentic.acp.RequestPermission
            --- @diagnostic disable-next-line: assign-type-mismatch, missing-fields
            local malformed = { sessionId = "s1", toolCall = 42 }

            -- `vim.schedule` is stubbed, so a throw from the scheduled body
            -- escapes into `drain` instead of dying on the (real) event loop.
            -- Captured here so the payload assertions below report the failure.
            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(19, malformed)

                drain(queue)
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 1)
            assert.equal(sent[1].id, 19)
            assert.equal(sent[1].result.outcome.outcome, "cancelled")
            assert.equal(asked.call_count, 0)
        end)

        it("answers selected when the user picks an option", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()
            --- @type { event: string, tool_call_id: string }[]
            local events = {}

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function(message)
                    events[#events + 1] = {
                        event = "update",
                        tool_call_id = message.tool_call_id,
                    }
                end,
                on_request_permission = function(request, callback)
                    events[#events + 1] = {
                        event = "request",
                        tool_call_id = request.toolCall.toolCallId,
                    }
                    callback("allow_once")
                end,
            }

            client.subscribers["s1"] = handlers
            --- @diagnostic disable-next-line: invisible
            client:__handle_request_permission(11, REQUEST)

            drain(queue)

            assert.same({
                { event = "update", tool_call_id = "tc-1" },
                { event = "request", tool_call_id = "tc-1" },
            }, events)
            assert.equal(1, #sent)
            assert.same({
                outcome = { outcome = "selected", optionId = "allow_once" },
            }, sent[1].result)
        end)

        -- The subprocess is shared across every session, so a stranded `id`
        -- hangs all of them, not just this one.
        it("answers cancelled when on_request_permission throws", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function()
                    error("boom in on_request_permission")
                end,
            }

            client.subscribers["s1"] = handlers

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(21, REQUEST)

                drain(queue)
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 1)
            assert.equal(sent[1].id, 21)
            assert.equal(sent[1].result.outcome.outcome, "cancelled")
            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match(
                    "boom in on_request_permission"
                )
            )
        end)

        -- The permission flow renders the tool call before prompting, so a
        -- throw in `on_tool_call_update` aborts the dispatch before
        -- `on_request_permission` is ever reached.
        it("answers cancelled when on_tool_call_update throws", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            local asked = spy.new(function() end)

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function()
                    error("boom in on_tool_call_update")
                end,
                on_request_permission = function(request, callback)
                    asked(request, callback)
                end,
            }

            client.subscribers["s1"] = handlers

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(23, REQUEST)

                drain(queue)
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 1)
            assert.equal(sent[1].id, 23)
            assert.equal(sent[1].result.outcome.outcome, "cancelled")
            assert.equal(asked.call_count, 0)
        end)

        -- `toolCall` is a table, so the pre-dispatch type guard passes, but
        -- `update.content` elements are unchecked: `content.type` on a number
        -- throws inside the scheduled `__build_tool_call_message`.
        it(
            "answers cancelled when the nested tool call content is malformed",
            function()
                local client = create_ready_client()
                local sent = capture_sent()
                local queue = queue_schedules()

                local asked = spy.new(function() end)

                --- @type agentic.acp.ClientHandlers
                local handlers = {
                    on_session_update = function() end,
                    on_error = function() end,
                    on_tool_call = function() end,
                    on_tool_call_update = function() end,
                    on_request_permission = function(request, callback)
                        asked(request, callback)
                    end,
                }

                client.subscribers["s1"] = handlers

                --- @type agentic.acp.RequestPermission
                --- @diagnostic disable-next-line: missing-fields
                local malformed = {
                    sessionId = "s1",
                    --- @diagnostic disable-next-line: assign-type-mismatch
                    toolCall = { toolCallId = "t1", content = { 5 } },
                }

                local ok, err = pcall(function()
                    --- @diagnostic disable-next-line: invisible
                    client:__handle_request_permission(25, malformed)

                    drain(queue)
                end)
                assert.equal(ok, true)
                assert.is_nil(err)

                assert.equal(#sent, 1)
                assert.equal(sent[1].id, 25)
                assert.equal(sent[1].result.outcome.outcome, "cancelled")
                assert.equal(asked.call_count, 0)
            end
        )

        -- The `id` was already answered before the throw. A second
        -- `__send_result` on the same `id` is a protocol violation, so the
        -- dispatch guard must not overwrite a real selection with a cancel.
        it("answers once when the handler answers and then throws", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function(_request, callback)
                    callback("allow_once")
                    error("boom after answering")
                end,
            }

            client.subscribers["s1"] = handlers

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(27, REQUEST)

                drain(queue)
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 1)
            assert.equal(sent[1].id, 27)
            assert.same({
                outcome = { outcome = "selected", optionId = "allow_once" },
            }, sent[1].result)
            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("boom after answering")
            )
        end)
    end)

    -- An agent can leave several permission requests outstanding at once and the
    -- user may answer them in any order, or never. `answer`/`answered` are
    -- per-invocation locals, so each `id` must carry its own state: a shared flag
    -- would drop the second answer, a shared `answer` would cross the wires.
    -- Every case uses DISTINCT ids, tool_call_ids and option ids so a cross-wire
    -- fails instead of coincidentally matching.
    describe("__handle_request_permission concurrency", function()
        --- @param n integer
        --- @param session_id string|nil Defaults to "s1"
        --- @return agentic.acp.RequestPermission request
        local function make_request(n, session_id)
            --- @type agentic.acp.RequestPermission
            --- @diagnostic disable-next-line: missing-fields
            local request = {
                sessionId = session_id or "s1",
                toolCall = { toolCallId = "tc-" .. n, kind = "edit" },
                options = {
                    {
                        optionId = "opt-" .. n,
                        name = "Allow " .. n,
                        kind = "allow_once",
                    },
                },
            }

            return request
        end

        --- Collects one `answer` callback per request, keyed by tool_call_id, so
        --- a test can invoke them in an order of its choosing.
        --- @param answers table<string, fun(option_id: string|nil)>
        --- @return agentic.acp.ClientHandlers handlers
        local function collecting_handlers(answers)
            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function(request, callback)
                    answers[request.toolCall.toolCallId] = callback
                end,
            }

            return handlers
        end

        --- @param sent table[]
        --- @return table<number, string> outcome_by_id
        local function outcomes_by_id(sent)
            --- @type table<number, string>
            local by_id = {}

            for _, frame in ipairs(sent) do
                by_id[frame.id] = frame.result.outcome.optionId
                    or frame.result.outcome.outcome
            end

            return by_id
        end

        it("answers two outstanding requests in reverse order", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}
            client.subscribers["s1"] = collecting_handlers(answers)

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(101, make_request(1))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(102, make_request(2))

                drain(queue)

                -- Reverse order: the SECOND request is answered first.
                answers["tc-2"]("opt-2")
                answers["tc-1"]("opt-1")
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 2)

            -- Frame order follows answer order, and each id keeps its OWN option.
            assert.equal(sent[1].id, 102)
            assert.same({
                outcome = { outcome = "selected", optionId = "opt-2" },
            }, sent[1].result)
            assert.equal(sent[2].id, 101)
            assert.same({
                outcome = { outcome = "selected", optionId = "opt-1" },
            }, sent[2].result)
        end)

        it("answers three outstanding requests middle-first", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}
            client.subscribers["s1"] = collecting_handlers(answers)

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(201, make_request(1))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(202, make_request(2))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(203, make_request(3))

                drain(queue)

                answers["tc-2"]("opt-2")
                answers["tc-3"]("opt-3")
                answers["tc-1"]("opt-1")
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 3)
            assert.same({
                [201] = "opt-1",
                [202] = "opt-2",
                [203] = "opt-3",
            }, outcomes_by_id(sent))
        end)

        it("leaves an unanswered request outstanding", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}
            client.subscribers["s1"] = collecting_handlers(answers)

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(301, make_request(1))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(302, make_request(2))

                drain(queue)

                answers["tc-2"]("opt-2")
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            -- Answering one must not answer the other on its behalf.
            assert.equal(#sent, 1)
            assert.equal(sent[1].id, 302)
            assert.same({
                outcome = { outcome = "selected", optionId = "opt-2" },
            }, sent[1].result)
        end)

        -- A throw is scoped to the `id` that threw: the dispatch guard cancels
        -- only its own request, never a sibling still waiting on the user.
        it("cancels only the request whose dispatch throws", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function(request, callback)
                    if request.toolCall.toolCallId == "tc-1" then
                        error("boom in tc-1")
                    end

                    answers[request.toolCall.toolCallId] = callback
                end,
            }

            client.subscribers["s1"] = handlers

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(401, make_request(1))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(402, make_request(2))

                drain(queue)

                answers["tc-2"]("opt-2")
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 2)
            assert.same({
                [401] = "cancelled",
                [402] = "opt-2",
            }, outcomes_by_id(sent))
        end)

        -- `cancel_session` nils the subscriber between the two dispatches. The
        -- first already holds its `answer` closure and still resolves normally;
        -- the second re-resolves inside `vim.schedule`, finds nothing, and
        -- cancels.
        it("cancels only the request left without a subscriber", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}
            client.subscribers["s1"] = collecting_handlers(answers)

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(501, make_request(1))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(502, make_request(2))

                -- Only the FIRST scheduled body runs while the subscriber lives.
                queue[1]()
                answers["tc-1"]("opt-1")

                client.subscribers["s1"] = nil
                queue[2]()
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 2)
            assert.same({
                [501] = "opt-1",
                [502] = "cancelled",
            }, outcomes_by_id(sent))
            assert.is_nil(answers["tc-2"])
        end)

        -- The subprocess is shared across sessions (ADR 0004), so a request
        -- stuck on one session must not strand another's. Answered out of
        -- order, and `s2` throws, which is that failure expressed across the
        -- session boundary.
        it("keeps requests on different sessions independent", function()
            local client = create_ready_client()
            local sent = capture_sent()
            local queue = queue_schedules()

            --- @type table<string, fun(option_id: string|nil)>
            local answers = {}
            client.subscribers["s1"] = collecting_handlers(answers)

            --- @type agentic.acp.ClientHandlers
            local throwing = {
                on_session_update = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
                on_request_permission = function()
                    error("boom in s2")
                end,
            }

            client.subscribers["s2"] = throwing

            local ok, err = pcall(function()
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(601, make_request(1, "s1"))
                --- @diagnostic disable-next-line: invisible
                client:__handle_request_permission(602, make_request(2, "s2"))

                drain(queue)

                -- s2 already cancelled itself by throwing; s1 answers after it.
                answers["tc-1"]("opt-1")
            end)
            assert.equal(ok, true)
            assert.is_nil(err)

            assert.equal(#sent, 2)

            -- s2's throw cancels only its own `id`; s1 keeps its own optionId.
            assert.equal(sent[1].id, 602)
            assert.same({ outcome = { outcome = "cancelled" } }, sent[1].result)
            assert.equal(sent[2].id, 601)
            assert.same({
                outcome = { outcome = "selected", optionId = "opt-1" },
            }, sent[2].result)
            assert.is_nil(answers["tc-2"])
        end)
    end)

    describe("__build_tool_call_message", function()
        it("handles vim.NIL content and locations (JSON null)", function()
            local client = create_ready_client()

            assert.has_no_errors(function()
                ---@diagnostic disable: invisible, assign-type-mismatch
                client:__build_tool_call_message({
                    toolCallId = "tc-1",
                    kind = "edit",
                    content = vim.NIL,
                    locations = vim.NIL,
                    rawInput = vim.NIL,
                })
                ---@diagnostic enable: invisible, assign-type-mismatch
            end)
        end)

        it("uses rawInput command as title and description as body", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = {
                    command = "rm demo.md",
                    description = "Remove demo.md file",
                },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal("rm demo.md", message.argument)
            assert.same({ "Remove demo.md file" }, message.body)
        end)

        it("uses rawInput command as title with no description body", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = { command = "ls -la" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal("ls -la", message.argument)
            assert.equal(nil, message.body)
        end)

        it("falls back to rawInput JSON for empty command", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = { command = "", other = "value here" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal("bash", message.argument)
            assert.is_true(type(message.body) == "table")
            assert.is_true(#message.body > 1)
        end)

        it("ignores empty description, sets only command title", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = { command = "ls -la", description = "" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal("ls -la", message.argument)
            assert.equal(nil, message.body)
        end)

        it("falls back to rawInput JSON when no command field", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = { foo = "bar baz" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.is_true(type(message.body) == "table")
            assert.is_true(#message.body > 1)
            local joined = table.concat(message.body, "\n")
            assert.is_true(joined:find('"foo": "bar baz"') ~= nil)
        end)

        it("does not inject body for empty rawInput", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "bash",
                rawInput = vim.empty_dict(),
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal(nil, message.body)
        end)

        it("keeps content-derived body over rawInput JSON", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "execute",
                title = "ls",
                rawInput = { command = "ls" },
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "List files" },
                    },
                },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.same({ "List files" }, message.body)
            local joined = table.concat(message.body, "\n")
            assert.is_true(joined:find('"command"') == nil)
        end)

        it("does not inject body for read kind", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "read",
                rawInput = { file_path = "/tmp/x" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.equal(nil, message.body)
        end)

        it("keeps edit diff and skips rawInput body injection", function()
            local client = create_ready_client()

            ---@diagnostic disable: invisible, assign-type-mismatch
            local message = client:__build_tool_call_message({
                toolCallId = "tc-x",
                kind = "edit",
                rawInput = { newString = "a", oldString = "b" },
            })
            ---@diagnostic enable: invisible, assign-type-mismatch

            assert.is_true(message.diff ~= nil)
            assert.equal(nil, message.body)
        end)
    end)

    describe("request watchdog", function()
        local uv = vim.uv or vim.loop
        local original_schedule
        --- @type agentic.acp.ACPClient|nil
        local watched_client

        before_each(function()
            -- Run scheduled work inline so the stall/send-fail paths, which
            -- defer rejection via vim.schedule, resolve within the test.
            original_schedule = vim.schedule
            vim.schedule = function(fn)
                fn()
            end
        end)

        after_each(function()
            vim.schedule = original_schedule
            -- Release any real timer a test left armed.
            if watched_client then
                watched_client:_disarm_watchdog()
                watched_client = nil
            end
        end)

        it(
            "rejects a pending control request with a timeout after silence",
            function()
                watched_client = create_ready_client(LIST_CAPS)

                --- @type agentic.acp.ACPError|nil
                local received_err
                watched_client:list_sessions("/tmp", function(_result, err)
                    received_err = err
                end)
                -- No response stubbed: the callback is still parked.
                assert.is_nil(received_err)

                -- Pretend no message has arrived for far longer than the timeout.
                watched_client._last_activity = uv.now() - 70000
                watched_client:_check_watchdog()

                assert.is_not_nil(received_err)
                --- @cast received_err agentic.acp.ACPError
                assert.equal(
                    watched_client.ERROR_CODES.TIMEOUT_ERROR,
                    received_err.code
                )
            end
        )

        it("does not trip while inbound activity keeps arriving", function()
            watched_client = create_ready_client(LIST_CAPS)

            --- @type agentic.acp.ACPError|nil
            local received_err
            watched_client:list_sessions("/tmp", function(_result, err)
                received_err = err
            end)

            -- Activity just happened: the silence window has not elapsed.
            watched_client._last_activity = uv.now()
            watched_client:_check_watchdog()

            assert.is_nil(received_err)
        end)

        it(
            "spares a pending request if activity resumes before stall handler fires",
            function()
                watched_client = create_ready_client(LIST_CAPS)

                --- @type agentic.acp.ACPError|nil
                local received_err
                watched_client:list_sessions("/tmp", function(_result, err)
                    received_err = err
                end)

                -- Simulate a response arriving in the vim.schedule gap between
                -- _check_watchdog disarming and _on_request_stall running.
                -- The stall handler must re-check _last_activity and bail out.
                watched_client._last_activity = uv.now()
                watched_client:_on_request_stall(60000)

                assert.is_nil(received_err)
            end
        )

        it("never times out session/prompt, even after long silence", function()
            watched_client = create_ready_client(LOAD_CAPS)

            --- @type agentic.acp.ACPError|nil
            local received_err
            watched_client:send_prompt("sess-1", {}, function(_result, err)
                received_err = err
            end)

            -- A prompt must not arm the silence watchdog at all.
            assert.is_nil(watched_client._watchdog_timer)

            watched_client._last_activity = uv.now() - 70000
            watched_client:_check_watchdog()

            assert.is_nil(received_err)
        end)

        it(
            "times out a stalled control request without touching an in-flight prompt",
            function()
                watched_client = create_ready_client(LIST_CAPS)

                --- @type agentic.acp.ACPError|nil
                local prompt_err
                watched_client:send_prompt("sess-1", {}, function(_result, err)
                    prompt_err = err
                end)

                --- @type agentic.acp.ACPError|nil
                local control_err
                watched_client:list_sessions("/tmp", function(_result, err)
                    control_err = err
                end)

                watched_client._last_activity = uv.now() - 70000
                watched_client:_check_watchdog()

                -- Only the control request is rejected; the prompt is left alone.
                assert.is_not_nil(control_err)
                --- @cast control_err agentic.acp.ACPError
                assert.equal(
                    watched_client.ERROR_CODES.TIMEOUT_ERROR,
                    control_err.code
                )
                assert.is_nil(prompt_err)
            end
        )

        it("rejects immediately when the transport send fails", function()
            watched_client = create_ready_client(LIST_CAPS)
            transport_send_stub:reset()
            transport_send_stub:invokes(function()
                return false
            end)

            --- @type agentic.acp.ACPError|nil
            local received_err
            watched_client:list_sessions("/tmp", function(_result, err)
                received_err = err
            end)

            assert.is_not_nil(received_err)
            --- @cast received_err agentic.acp.ACPError
            assert.equal(
                watched_client.ERROR_CODES.TRANSPORT_ERROR,
                received_err.code
            )
        end)

        it("disarms the timer once no control request is pending", function()
            watched_client = create_ready_client(LIST_CAPS)
            -- The initialize round-trip during setup resolved, so nothing armed.
            assert.is_nil(watched_client._watchdog_timer)

            stub_send_response(watched_client, "session/list", {
                sessions = {},
            }, nil)
            watched_client:list_sessions("/tmp", function() end)

            -- Response resolved synchronously, so the watchdog disarmed again.
            assert.is_nil(watched_client._watchdog_timer)
        end)
    end)

    describe("reconnect", function()
        local original_schedule

        before_each(function()
            -- The drain on disconnect defers rejection via vim.schedule; run it
            -- inline so it resolves within the test.
            original_schedule = vim.schedule
            vim.schedule = function(fn)
                fn()
            end
        end)

        after_each(function()
            vim.schedule = original_schedule
        end)

        it("stops the transport and re-initializes back to ready", function()
            local client = create_ready_client(LOAD_CAPS)
            assert.equal("ready", client.state)

            -- stop() drives the connection down; _connect() needs "disconnected".
            transport_stop_stub:invokes(function()
                if captured_on_state_change then
                    captured_on_state_change("disconnected")
                end
            end)

            -- A fresh start() reconnects and answers the new initialize.
            transport_start_stub:reset()
            transport_start_stub:invokes(function()
                if captured_on_state_change then
                    captured_on_state_change("connected")
                end
            end)
            transport_send_stub:reset()
            transport_send_stub:invokes(function(_self, data)
                local decoded = vim.json.decode(data)
                if decoded.method == "initialize" and captured_on_message then
                    captured_on_message({
                        jsonrpc = "2.0",
                        id = decoded.id,
                        result = {
                            protocolVersion = 1,
                            agentCapabilities = LOAD_CAPS,
                            agentInfo = { name = "test" },
                        },
                    })
                end
            end)

            client:reconnect()

            assert.spy(transport_stop_stub).was.called(1)
            assert.spy(transport_start_stub).was.called(1)
            assert.equal("ready", client.state)
        end)

        it(
            "rejects in-flight requests when it tears the connection down",
            function()
                local client = create_ready_client(LOAD_CAPS)

                --- @type agentic.acp.ACPError|nil
                local prompt_err
                client:send_prompt("sess-1", {}, function(_result, err)
                    prompt_err = err
                end)

                -- stop() reports the drop, which must drain pending callbacks.
                transport_stop_stub:invokes(function()
                    if captured_on_state_change then
                        captured_on_state_change("disconnected")
                    end
                end)
                transport_start_stub:reset()
                transport_start_stub:invokes(function() end)

                client:reconnect()

                assert.is_not_nil(prompt_err)
            end
        )
    end)
end)
