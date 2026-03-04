local ACPClient = require("agentic.acp.acp_client")

--- Cline-specific adapter that extends ACPClient with Cline-specific behaviors
--- @class agentic.acp.ClineACPAdapter : agentic.acp.ACPClient
local ClineACPAdapter = setmetatable({}, { __index = ACPClient })
ClineACPAdapter.__index = ClineACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClineACPAdapter
function ClineACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, ClineACPAdapter) --[[@as agentic.acp.ClineACPAdapter]]

    return self
end

return ClineACPAdapter
