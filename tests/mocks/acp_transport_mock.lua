--- Mock implementation of agentic.acp.ACPTransportModule for testing
--- @class agentic.acp.ACPTransportModuleMock
local M = {}

--- Create a mock stdio transport for testing
--- @param config agentic.acp.StdioTransportConfig
--- @param callbacks agentic.acp.TransportCallbacks
--- @return agentic.acp.ACPTransportInstance
function M.create_stdio_transport(config, callbacks)
    --- @type agentic.acp.ACPTransportInstance
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

    --- @param data string
    function transport:send(data)
        if transport._stopped then
            return false
        end
        return true
    end

    function transport:start()
        transport._started = true
        callbacks.on_state_change("connecting")
    end

    function transport:stop()
        transport._stopped = true
        callbacks.on_state_change("disconnected")
    end

    return transport
end

return M
