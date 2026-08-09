--- Mock implementation of agentic.acp.ACPTransportModule for testing
--- @alias tests.mocks.ACPTransportDeliveryMode
--- | "direct"
--- | "fast_event"

--- @class agentic.acp.ACPTransportModuleMock
local M = {}

--- Create a mock stdio transport for testing
--- @param config agentic.acp.StdioTransportConfig
--- @param callbacks agentic.acp.TransportCallbacks
--- @return agentic.acp.ACPTransportInstance
function M.create_stdio_transport(config, callbacks)
    --- @class tests.mocks.ACPTransportInstance : agentic.acp.ACPTransportInstance
    local transport = {
        stdin = nil,
        stdout = nil,
        process = nil,
        _config = config,
        _callbacks = callbacks,
        _started = false,
        _stopped = false,
        callbacks = callbacks,
    }

    --- @param _data string
    function transport:send(_data)
        if self._stopped then
            return false
        end
        return true
    end

    function transport:start()
        self._started = true
        self._callbacks.on_state_change("connecting")
    end

    function transport:stop()
        self._stopped = true
        self._callbacks.on_state_change("disconnected")
    end

    --- @param message agentic.acp.ResponseRaw
    --- @param mode tests.mocks.ACPTransportDeliveryMode|nil
    --- @return uv.uv_timer_t|nil timer
    function transport:deliver(message, mode)
        if mode == "fast_event" then
            local timer = assert(vim.uv.new_timer())
            timer:start(0, 0, function()
                timer:close()
                self._callbacks.on_message(message)
            end)
            return timer
        else
            self._callbacks.on_message(message)
        end
    end

    return transport
end

return M
