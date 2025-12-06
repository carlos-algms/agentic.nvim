local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
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

--- @param params table
function ClaudeACPAdapter:__handle_session_update(params)
    if params.update.sessionUpdate == "tool_call" then
        self:_handle_tool_call(params.sessionId, params.update)
    else
        ACPClient.__handle_session_update(self, params)
    end
end

--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function ClaudeACPAdapter:_handle_tool_call(session_id, update)
    -- expected state, claude is sending an empty content first, followed by the actual content
    if vim.tbl_isempty(update.content) then
        return
    end

    local kind = update.kind
    local status = update.status
    local argument
    -- FIXIT: check if some tool calls have body

    if kind == "read" or kind == "edit" then
        argument = FileSystem.to_smart_path(update.rawInput.file_path)
    elseif kind == "fetch" then
        if update.rawInput.query then
            kind = "WebSearch"
        end

        argument = update.rawInput.query
            or update.rawInput.url
            or "unknown fetch"
    else
        local command = update.rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        argument = command or update.title or ""
    end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = status,
        argument = argument,
    }

    local subscriber = self:__get_subscriber(session_id)
    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        subscriber.on_tool_call(message)
    end)
end

return ClaudeACPAdapter
