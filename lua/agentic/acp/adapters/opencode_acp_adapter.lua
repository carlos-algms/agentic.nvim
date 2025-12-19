local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

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
    -- generating an empty tool call block on purpose,
    -- all OpenCode's useful data comes in tool_call_update
    -- having an empty tool call block helps unnecessary data conversions

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind,
        status = update.status,
        argument = update.title or "pending...",
    }

    if update.title == "list" then
        -- hack to keep consistency with other Providers
        -- OpenCode uses `read`, and the message writer will omit it's output if we kept this as read.
        message.kind = "search"
    elseif update.title == "websearch" then
        message.kind = "WebSearch"
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Specific OpenCode structure - created to avoid confusion with the standard ACP types,
--- as only OpenCode sends these fields
--- @class agentic.acp.OpenCodeToolCallRawInput : agentic.acp.RawInput
--- @field filePath? string
--- @field newString? string
--- @field oldString? string
--- @field replaceAll? boolean
--- @field error? string

--- @class agentic.acp.OpenCodeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function OpenCodeACPAdapter:_handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    ---@cast update agentic.acp.OpenCodeToolCallUpdate

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    if update.status == "completed" or update.status == "failed" then
        if update.content and update.content[1] then
            local content = update.content[1].content
            if content and content.text then
                message.body = vim.split(content.text, "\n")
            end
        end
    else
        if update.rawInput then
            if update.rawInput.newString then
                message.argument =
                    FileSystem.to_smart_path(update.rawInput.filePath or "")

                message.diff = {
                    new = vim.split(update.rawInput.newString, "\n"),
                    old = vim.split(update.rawInput.oldString or "", "\n"),
                    all = update.rawInput.replaceAll or false,
                }
            elseif update.rawInput.url then -- fetch command
                message.argument = update.rawInput.url
            elseif update.rawInput.query then -- WebSearch command
                message.body = vim.split(update.rawInput.query, "\n")
            elseif update.rawInput.command then
                message.argument = update.rawInput.command

                if update.rawInput.description then
                    message.body = vim.split(update.rawInput.description, "\n")
                end
            elseif update.rawInput.error then
                message.body = vim.split(update.rawInput.error, "\n")
            end
        elseif update.rawOutput then -- rawOutput doesn't seem standard, also we don't have types
            if update.rawOutput.output then
                message.body = vim.split(update.rawOutput.output, "\n")
            elseif update.rawOutput.error then
                message.body = vim.split(update.rawOutput.error, "\n")
            end
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return OpenCodeACPAdapter
