local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- OpenCode-specific adapter that extends ACPClient with OpenCode-specific behaviors
--- @class agentic.acp.OpenCodeACPAdapter : agentic.acp.ACPClient
local OpenCodeACPAdapter = setmetatable({}, { __index = ACPClient })
OpenCodeACPAdapter.__index = OpenCodeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.OpenCodeACPAdapter
function OpenCodeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, OpenCodeACPAdapter) --[[@as agentic.acp.OpenCodeACPAdapter]]

    return self
end

--- @param params table
function OpenCodeACPAdapter:__handle_session_update(params)
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
function OpenCodeACPAdapter:_handle_tool_call(session_id, update)
    local kind = update.kind
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = "",
    }

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @class agentic.acp.ToolCallRawInputOpenCode : agentic.acp.RawInput
--- @field filePath? string
--- @field newString? string
--- @field oldString? string
--- @field replaceAll? boolean

--- @class agentic.acp.ToolCallUpdateOpenCode : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.ToolCallRawInputOpenCode

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function OpenCodeACPAdapter:_handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    ---@cast update agentic.acp.ToolCallUpdateOpenCode

    if update.status == "completed" or update.status == "failed" then
        --- @type agentic.ui.MessageWriter.ToolCallBase
        local message = {
            tool_call_id = update.toolCallId,
            status = update.status,
        }

        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call_update(message)
        end)

        return
    end

    -- Why I need to generate synthetic tool calls:
    -- 1. OpenCode ACP sends tool_call with empty rawInput, content, and locations, it just contains status "pending"
    -- 2. Later, it sends tool_call_update with actual usable data, but it's status "in_progress"
    -- And tool_call_update was never planned to fully write or rewrite tool calls blocks in the chat buffer.

    if update.rawInput then
        if update.rawInput.newString then
            message.argument =
                FileSystem.to_smart_path(update.rawInput.filePath or "")

            message.diff = {
                new = vim.split(update.rawInput.newString, "\n"),
                old = vim.split(update.rawInput.oldString or "", "\n"),
                all = update.rawInput.replaceAll or false,
            }
        end
    end
end

return OpenCodeACPAdapter
