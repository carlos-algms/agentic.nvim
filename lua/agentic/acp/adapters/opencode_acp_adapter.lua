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

--- @protected
--- @param session_id string
--- @param update agentic.acp.OpenCodeToolCallMessage
function OpenCodeACPAdapter:__handle_tool_call(session_id, update)
    -- generating an empty tool call block on purpose,
    -- all OpenCode's useful data comes in tool_call_update
    -- having an empty tool call block helps unnecessary data conversions

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind,
        status = update.status,
        argument = update.title ~= update.kind and update.title or "pending...",
    }

    if update.title == "list" then
        -- hack to keep consistency with other Providers
        -- OpenCode uses `read`, and the message writer will omit it's output if we kept this as read.
        message.kind = "search"
    elseif update.title == "websearch" or update.title == "google_search" then
        message.kind = "WebSearch"
    elseif update.title == "task" then
        -- rawInput is empty in tool_call, only populated in tool_call_update
        message.kind = "SubAgent"
    elseif update.title == "skill" then
        message.kind = "Skill"
        message.argument = update.rawInput and update.rawInput.name
            or "unknown skill"
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Specific OpenCode structure - created to avoid confusion with the standard ACP types,
--- as only OpenCode sends these fields
--- @class agentic.acp.OpenCodeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @class agentic.acp.OpenCodeToolCallRawInput : agentic.acp.RawInput
--- @field filePath? string
--- @field newString? string
--- @field oldString? string
--- @field replaceAll? boolean
--- @field error? string
--- @field name? string Skill name
--- @field subagent_type? string For sub-agent tasks
--- @field description? string For sub-agent tasks
--- @field prompt? string For sub-agent tasks

--- @class agentic.acp.OpenCodeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field kind? agentic.acp.ToolKind
--- @field title? string
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function OpenCodeACPAdapter:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    ---@cast update agentic.acp.OpenCodeToolCallUpdate

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    -- Detect SubAgent for ALL statuses (kind comes as "other" from OpenCode)
    if update.rawInput and update.rawInput.subagent_type then
        message.kind = "SubAgent"
    end

    if update.status == "completed" or update.status == "failed" then
        if
            update.kind == "other"
            and update.rawInput
            and update.rawInput.name
        then
            message.body = { update.title or "" }
        else
            message.body = self:extract_content_body(update)
        end
    else
        if update.rawInput then
            if update.rawInput.newString then
                message.argument =
                    FileSystem.to_smart_path(update.rawInput.filePath or "")

                local old_string = update.rawInput.oldString

                message.diff = {
                    new = self:safe_split(update.rawInput.newString),
                    old = self:safe_split(old_string),
                    all = update.rawInput.replaceAll or false,
                }
            elseif update.rawInput.url then -- fetch command
                message.argument = update.rawInput.url
            elseif update.rawInput.query then -- WebSearch command
                message.argument = update.rawInput.query
                message.body = self:safe_split(update.rawInput.query)
            elseif update.rawInput.command then
                message.argument = update.rawInput.command

                if update.rawInput.description then
                    message.body = self:safe_split(update.rawInput.description)
                end
            elseif update.rawInput.subagent_type then
                message.argument = string.format(
                    "%s: %s",
                    update.rawInput.subagent_type,
                    update.rawInput.description or ""
                )
                if update.rawInput.prompt then
                    message.body = self:safe_split(update.rawInput.prompt)
                end
            elseif update.rawInput.filePath then
                message.argument =
                    FileSystem.to_smart_path(update.rawInput.filePath)
            elseif update.rawInput.name then
                message.argument = update.rawInput.name
            elseif update.rawInput.error then
                message.body = self:safe_split(update.rawInput.error)
            end
        elseif update.rawOutput then -- rawOutput doesn't seem standard, also we don't have types
            if update.rawOutput.output then
                message.body = self:safe_split(update.rawOutput.output)
            elseif update.rawOutput.error then
                message.body = self:safe_split(update.rawOutput.error)
            end
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return OpenCodeACPAdapter
