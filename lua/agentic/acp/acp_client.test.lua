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

    --- Captured on_state_change callback from create_stdio_transport
    --- @type fun(state: agentic.acp.ClientConnectionState)|nil
    local captured_on_state_change

    --- Captured on_message callback from create_stdio_transport
    --- @type fun(message: agentic.acp.ResponseRaw)|nil
    local captured_on_message

    --- Creates an ACPClient instance with mocked transport, already in "ready" state.
    --- @param agent_caps agentic.acp.AgentCapabilities|nil
    --- @return agentic.acp.ACPClient client
    local function create_ready_client(agent_caps)
        -- Capture the transport callbacks passed to create_stdio_transport
        create_transport_stub:invokes(function(_config, callbacks)
            captured_on_state_change = callbacks.on_state_change
            captured_on_message = callbacks.on_message
            return mock_transport
        end)

        -- transport:start triggers on_state_change("connected")
        transport_start_stub:invokes(function()
            if captured_on_state_change then
                captured_on_state_change("connected")
            end
        end)

        -- Intercept the initialize request and respond immediately
        -- Note: transport:send(data) passes (self, data) to the stub
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

        -- Clear send stub for test assertions
        transport_send_stub:reset()
        transport_send_stub:invokes(function() end)

        return client
    end

    before_each(function()
        package.loaded["agentic.acp.acp_client"] = nil
        package.loaded["agentic.acp.acp_transport"] = nil
        package.loaded["agentic.utils.logger"] = nil

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
        it("returns false when agent_capabilities is nil", function()
            local client = create_ready_client(nil)

            local result = client:list_sessions("/tmp", function() end)

            assert.is_false(result)
            assert.spy(transport_send_stub).was.called(0)
        end)

        it("returns false when sessionCapabilities is nil", function()
            local client = create_ready_client({
                loadSession = true,
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            local result = client:list_sessions("/tmp", function() end)

            assert.is_false(result)
            assert.spy(transport_send_stub).was.called(0)
        end)

        it("returns false when sessionCapabilities.list is falsy", function()
            local client = create_ready_client({
                loadSession = true,
                sessionCapabilities = { list = false },
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            local result = client:list_sessions("/tmp", function() end)

            assert.is_false(result)
            assert.spy(transport_send_stub).was.called(0)
        end)

        it("returns true and sends request when capable", function()
            local client = create_ready_client({
                loadSession = true,
                sessionCapabilities = { list = true },
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            local result = client:list_sessions("/tmp", function() end)

            assert.is_true(result)
            assert.spy(transport_send_stub).was.called(1)

            -- calls[1][1] is self (mock_transport), [2] is the actual data
            local sent_data = transport_send_stub.calls[1][2]
            local decoded = vim.json.decode(sent_data)
            assert.equal("session/list", decoded.method)
            assert.equal("/tmp", decoded.params.cwd)
        end)

        it("callback receives SessionListResponse on success", function()
            local client = create_ready_client({
                loadSession = true,
                sessionCapabilities = { list = true },
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            --- @type agentic.acp.SessionListResponse|nil
            local received_result
            --- @type agentic.acp.ACPError|nil
            local received_err

            -- Capture the request id from the send
            transport_send_stub:invokes(function(_self, data)
                local decoded = vim.json.decode(data)
                if decoded.method == "session/list" then
                    local cb = client.callbacks[decoded.id]
                    if cb then
                        client.callbacks[decoded.id] = nil
                        cb({
                            sessions = {
                                {
                                    sessionId = "s1",
                                    cwd = "/tmp",
                                    title = "Session 1",
                                },
                            },
                        }, nil)
                    end
                end
            end)

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
            local client = create_ready_client({
                loadSession = true,
                sessionCapabilities = { list = true },
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            --- @type agentic.acp.SessionListResponse|nil
            local received_result
            --- @type agentic.acp.ACPError|nil
            local received_err

            transport_send_stub:invokes(function(_self, data)
                local decoded = vim.json.decode(data)
                if decoded.method == "session/list" then
                    local cb = client.callbacks[decoded.id]
                    if cb then
                        client.callbacks[decoded.id] = nil
                        cb(nil, { code = -32000, message = "Transport error" })
                    end
                end
            end)

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
        it("calls on_load_complete callback when response arrives", function()
            local client = create_ready_client({
                loadSession = true,
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            local complete_called = false

            transport_send_stub:invokes(function(_self, data)
                local decoded = vim.json.decode(data)
                if decoded.method == "session/load" then
                    local cb = client.callbacks[decoded.id]
                    if cb then
                        client.callbacks[decoded.id] = nil
                        cb({}, nil)
                    end
                end
            end)

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_request_permission = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
            }

            client:load_session("sid-1", "/tmp", {}, handlers, function()
                complete_called = true
            end)

            assert.is_true(complete_called)
        end)

        it("works without on_load_complete (backward compatible)", function()
            local client = create_ready_client({
                loadSession = true,
                promptCapabilities = {
                    image = false,
                    audio = false,
                    embeddedContext = false,
                },
            })

            transport_send_stub:invokes(function(_self, data)
                local decoded = vim.json.decode(data)
                if decoded.method == "session/load" then
                    local cb = client.callbacks[decoded.id]
                    if cb then
                        client.callbacks[decoded.id] = nil
                        cb({}, nil)
                    end
                end
            end)

            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_session_update = function() end,
                on_request_permission = function() end,
                on_error = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
            }

            -- Should not error when on_load_complete is omitted
            assert.has_no_errors(function()
                client:load_session("sid-1", "/tmp", {}, handlers)
            end)
        end)
    end)
end)
