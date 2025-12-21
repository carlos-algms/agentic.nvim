-- According to the ACP protocol, a single agent process can handle multiple sessions.
-- A session is an isolated conversation with its own state and and context.
-- This file maintain one Agent process per provider.
-- We should NOT spawn multiple agent processes, but create new sessions instead.
-- Documentation for reference: https://agentclientprotocol.com/protocol/session-setup.md

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentInstance
--- @field chat_widget agentic.ui.ChatWidget
--- @field agent_client agentic.acp.ACPClient

--- @class agentic.acp.AgentInstance
local AgentInstance = {}

--- A Keyed list of agent instances by name
--- @private
--- @type table<string, agentic.acp.ACPClient|nil>
AgentInstance._instances = {}

--- @param provider_name string
--- @param on_ready fun(client: agentic.acp.ACPClient)
function AgentInstance.get_instance(provider_name, on_ready)
    local client = AgentInstance._instances[provider_name]

    if client then
        if on_ready then
            on_ready(client)
        end
        return client
    end

    local config = Config.acp_providers[provider_name]

    if not config then
        error("No ACP provider configuration found for: " .. provider_name)
        return nil
    end

    Logger.debug(
        "Creating new ACP agent instance for provider: " .. provider_name
    )

    if provider_name == "claude-acp" then
        local ClaudeACPAdapter =
            require("agentic.acp.adapters.claude_acp_adapter")
        client = ClaudeACPAdapter:new(config, on_ready)
    elseif provider_name == "codex-acp" then
        local CodexACPAdapter =
            require("agentic.acp.adapters.codex_acp_adapter")
        client = CodexACPAdapter:new(config, on_ready)
    elseif provider_name == "gemini-acp" then
        local GeminiACPAdapter =
            require("agentic.acp.adapters.gemini_acp_adapter")
        client = GeminiACPAdapter:new(config, on_ready)
    elseif provider_name == "opencode-acp" then
        local OpenCodeACPAdapter =
            require("agentic.acp.adapters.opencode_acp_adapter")
        client = OpenCodeACPAdapter:new(config, on_ready)
    elseif provider_name == "cursor-acp" then
        local CursorACPAdapter =
            require("agentic.acp.adapters.cursor_acp_adapter")
        client = CursorACPAdapter:new(config, on_ready)
    else
        error("Unsupported ACP provider: " .. provider_name)
    end

    AgentInstance._instances[provider_name] = client

    return client
end

--- Cleanup all active instances and processes
--- This is called automatically on VimLeavePre and signal handlers
--- Can also be called manually if needed
function AgentInstance:cleanup_all()
    for _name, instance in pairs(self._instances) do
        if instance then
            pcall(function()
                instance:stop()
            end)
        end
    end

    self._instances = {}
end

return AgentInstance
