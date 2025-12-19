local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

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

--- @param params table
function CodexACPAdapter:__handle_session_update(params)
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
function CodexACPAdapter:_handle_tool_call(session_id, update)
    local kind = update.kind
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        local path = update.locations
                and update.locations[1]
                and update.locations[1].path
            or ""

        message.argument = FileSystem.to_smart_path(path)

        if kind == "edit" and update.content and update.content[1] then
            local content = update.content[1]
            local new_string = content.newText or ""
            local old_string = content.oldText or ""

            message.diff = {
                new = vim.split(new_string, "\n"),
                old = vim.split(old_string, "\n"),
            }
        end
    elseif
        update.rawInput
        and update.rawInput.parsed_cmd
        and update.rawInput.parsed_cmd[1]
    then
        message.argument = update.rawInput.parsed_cmd[1].cmd or ""
    else
        local command = update.rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or "unknown codex command"
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function CodexACPAdapter:_handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    if update.content and update.content[1] then
        local content = update.content[1]

        if content.type == "content" then
            message.body = vim.split(content.content.text, "\n")
        elseif content.type == "diff" then -- luacheck: ignore 542 -- intentional empty block
            -- ignore, already handled in tool call, we don't want to rerender diffs, as they don't change during updates
        else
            Logger.debug(
                "Unknown tool call update content type: "
                    ---@diagnostic disable-next-line: undefined-field -- it's expected this to be unknown
                    .. tostring(content.type)
            )
        end
    elseif update.rawOutput then
        message.body = vim.split(update.rawOutput.formatted_output or "", "\n")
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return CodexACPAdapter
