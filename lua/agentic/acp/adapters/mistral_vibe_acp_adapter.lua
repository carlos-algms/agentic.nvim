local ACPClient = require("agentic.acp.acp_client")

--- @class agentic.acp.MistralVibeACPAdapter : agentic.acp.ACPClient
local MistralVibeACPAdapter = setmetatable({}, { __index = ACPClient })
MistralVibeACPAdapter.__index = MistralVibeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.MistralVibeACPAdapter
function MistralVibeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, MistralVibeACPAdapter) --[[@as agentic.acp.MistralVibeACPAdapter]]

    return self
end

--- @param params table
function MistralVibeACPAdapter:__handle_session_update(params)
    local update_type = params.update.sessionUpdate

    if update_type == "user_message_chunk" then
        -- Ignore user message chunks, Agentic writes its own user messages and these can cause duplication
        return
    end

    ACPClient.__handle_session_update(self, params)
end

--- @class agentic.acp.MistralVibeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? string

--- @param update agentic.acp.MistralVibeToolCallMessage
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function MistralVibeACPAdapter:__build_tool_call_message(update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = "execute",
        status = update.status or "pending",
        argument = update.title,
        body = self:extract_content_body(update),
    }

    return message
end

return MistralVibeACPAdapter
