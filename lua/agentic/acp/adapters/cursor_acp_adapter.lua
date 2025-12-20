local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- Cursor-specific adapter that extends ACPClient with Cursor-specific behaviors
--- @class agentic.acp.CursorACPAdapter : agentic.acp.ACPClient
local CursorACPAdapter = setmetatable({}, { __index = ACPClient })
CursorACPAdapter.__index = CursorACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.CursorACPAdapter
function CursorACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, CursorACPAdapter) --[[@as agentic.acp.CursorACPAdapter]]

    return self
end

--- @param params table
function CursorACPAdapter:__handle_session_update(params)
    local type = params.update.sessionUpdate

    if type == "tool_call" then
        self:_handle_tool_call(params.sessionId, params.update)
    elseif type == "tool_call_update" then
        self:_handle_tool_call_update(params.sessionId, params.update)
    else
        ACPClient.__handle_session_update(self, params)
    end
end

--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function CursorACPAdapter:_handle_tool_call(session_id, update)
    local kind = update.kind
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    -- TODO: implement Cursor-agent tool calls

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function CursorACPAdapter:_handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    -- TODO: implement Cursor-agent tool call updates

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return CursorACPAdapter
