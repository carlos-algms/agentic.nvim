-- According to the ACP protocol, a single agent process can handle multiple sessions.
-- A session is an isolated conversation with its own state and and context.
-- This file maintain one Agent process per provider.
-- We should NOT spawn multiple agent processes, but create new sessions instead.
-- Documentation for reference: https://agentclientprotocol.com/protocol/session-setup.md

local Config = require("agentic.config")

--- @class agentic.acp.AgentInstance
--- @field chat_widget agentic.ui.ChatWidget
--- @field agent_client agentic.acp.ACPClient

--- @class agentic.acp.AgentInstance
local AgentInstance = {}

--- A Keyed list of agent instances by name
--- @type table<string, agentic.acp.ACPClient>
AgentInstance.instances = {}

--- @param provider_name string
function AgentInstance.get_instance(provider_name)
    local Client = require("agentic.acp.acp_client")

    if AgentInstance.instances[provider_name] ~= nil then
        return AgentInstance.instances[provider_name]
    end

    local provider_config = Config.acp_providers[provider_name] --[[@as agentic.acp.ProviderConfig|nil ]]

    if not provider_config then
        error("No ACP provider configuration found for: " .. provider_name)
        return nil
    end

    local agent_client = Client:new(provider_config)

    AgentInstance.instances[provider_name] = agent_client

    return agent_client
end

--- Cleanup all active instances and processes
--- This is called automatically on VimLeavePre and signal handlers
--- Can also be called manually if needed
function AgentInstance:cleanup_all()
    for _name, instance in pairs(self.instances) do
        if instance then
            pcall(function()
                instance:stop()
            end)
        end
    end

    self.instances = {}
end

return AgentInstance
