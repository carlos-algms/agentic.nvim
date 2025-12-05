local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")

--- Claude-specific adapter that extends ACPClient with Claude-specific behaviors
--- @class agentic.acp.ClaudeACPAdapter : agentic.acp.ACPClient
local ClaudeACPAdapter = setmetatable({}, { __index = ACPClient })
ClaudeACPAdapter.__index = ClaudeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClaudeACPAdapter
function ClaudeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, ClaudeACPAdapter) --[[@as agentic.acp.ClaudeACPAdapter]]

    return self
end

return ClaudeACPAdapter
