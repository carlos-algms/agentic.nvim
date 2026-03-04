local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.CodexParsedCommand
--- @field cmd? string
--- @field path? string
--- @field query? string|vim.NIL
--- @field type? string

--- @class agentic.acp.CodexRawInput : agentic.acp.RawInput
--- @field parsed_cmd? agentic.acp.CodexParsedCommand[]
--- @field action? agentic.acp.CodexRawInputAction

--- @class agentic.acp.CodexRawInputAction
--- @field type string
--- @field query? string
--- @field queries? string[]
--- @field url? string

--- @class agentic.acp.CodexToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.CodexRawInput

--- @class agentic.acp.CodexToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field title? string
--- @field rawInput? agentic.acp.CodexRawInput

--- Codex-specific adapter that extends ACPClient with Codex-specific behaviors
--- @class agentic.acp.CodexACPAdapter : agentic.acp.ACPClient
local CodexACPAdapter = setmetatable({}, { __index = ACPClient })
CodexACPAdapter.__index = CodexACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.CodexACPAdapter
function CodexACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, CodexACPAdapter) --[[@as agentic.acp.CodexACPAdapter]]

    return self
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.CodexToolCallMessage
function CodexACPAdapter:__handle_tool_call(session_id, update)
    local kind = update.kind
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status or "pending",
        argument = update.title or "unknown codex command",
    }

    if kind == "read" or kind == "edit" then
        local path = update.locations
                and update.locations[1]
                and update.locations[1].path
            or ""

        message.argument = FileSystem.to_smart_path(path)

        if kind == "edit" and update.content and update.content[1] then
            local content = update.content[1]
            local new_string = content.newText
            local old_string = content.oldText

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
            }
        end
    elseif update.rawInput then
        if update.rawInput.parsed_cmd and update.rawInput.parsed_cmd[1] then
            message.argument = update.rawInput.parsed_cmd[1].cmd or ""
        else
            local command = update.rawInput.command
            if type(command) == "table" then
                command = table.concat(command, " ")
            end

            message.argument = command
                or update.title
                or "unknown codex command"
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @protected
--- @param update agentic.acp.ToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function CodexACPAdapter:__build_tool_call_update(update)
    ---@cast update agentic.acp.CodexToolCallUpdate
    local message = ACPClient.__build_tool_call_update(self, update)

    if not message.body and update.rawOutput then
        message.body = self:safe_split(update.rawOutput.formatted_output)
    end

    local raw_input = update.rawInput
    local action = raw_input and raw_input.action

    if action and raw_input then
        local action_type = action.type

        if action_type == "search" then
            message.kind = "WebSearch"
            message.argument = action.query or raw_input.query
        elseif action_type == "open_page" then
            message.argument = action.url or raw_input.query
        end
    elseif update.title then
        message.argument = update.title
    end

    return message
end

return CodexACPAdapter
