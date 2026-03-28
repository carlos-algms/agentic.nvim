local assert = require("tests.helpers.assert")
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

    --- @type fun(state: agentic.acp.ClientConnectionState)|nil
    local captured_on_state_change

    --- @type fun(message: agentic.acp.ResponseRaw)|nil
    local captured_on_message

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

    before_each(function()
        package.loaded["agentic.acp.acp_client"] = nil
        package.loaded["agentic.acp.acp_transport"] = nil

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
        logger_debug_stub:revert()
        logger_debug_to_file_stub:revert()
        logger_notify_stub:revert()
        transport_send_stub:revert()
        transport_start_stub:revert()
        transport_stop_stub:revert()
        create_transport_stub:revert()
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

        it("works without on_load_complete (backward compatible)", function()
            local client = create_ready_client(LOAD_CAPS)

            stub_send_response(client, "session/load", {}, nil)

            assert.has_no_errors(function()
                client:load_session("sid-1", "/tmp", {}, NOOP_HANDLERS)
            end)
        end)
    end)
end)
