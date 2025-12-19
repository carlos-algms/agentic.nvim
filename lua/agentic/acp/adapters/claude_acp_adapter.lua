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
function ClaudeACPAdapter:_handle_tool_call(session_id, update)
    -- expected state, claude is sending an empty content first, followed by the actual content
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        return
    end

    local kind = update.kind
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(update.rawInput.file_path)

        if kind == "edit" then
            local new_string = update.rawInput.new_string or ""
            local old_string = update.rawInput.old_string or ""

            -- Claude might send content when creating new files
            new_string = update.rawInput.content or new_string

            message.diff = {
                new = vim.split(new_string, "\n"),
                old = vim.split(old_string, "\n"),
                all = update.rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if update.rawInput.query then
            -- To keep consistency with all other ACP providers
            message.kind = "WebSearch"
            message.argument = update.rawInput.query
        elseif update.rawInput.url then
            message.argument = update.rawInput.url

            if update.rawInput.prompt then
                message.argument = string.format(
                    "%s %s",
                    message.argument,
                    update.rawInput.prompt
                )
            end
        else
            message.argument = "unknown fetch"
        end
    else
        local command = update.rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or ""
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function ClaudeACPAdapter:_handle_tool_call_update(session_id, update)
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

        if
            content.type == "content"
            and content.content
            and content.content.text
        then
            message.body = vim.split(content.content.text, "\n")
        else
            Logger.debug("Unknown tool call update content type", {
                content_type = content.type,
                content = content.content,
                session_id = session_id,
                tool_call_id = update.toolCallId,
            })
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return ClaudeACPAdapter
