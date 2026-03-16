local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

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

--- @class agentic.acp.CursorToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field kind? agentic.acp.ToolKind
--- @field status? agentic.acp.ToolCallStatus
--- @field title? string

--- Build enriched update from rawInput fields that claude-agent-acp
--- sends on tool_call_update instead of tool_call.
--- @protected
--- @param update agentic.acp.CursorToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function CursorACPAdapter:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
        kind = update.kind,
        argument = update.title,
    }

    local content = update.content

    if content and content[1] then
        local item = content[1]

        if item.type == "diff" then
            local new_string = item.newText
            local old_string = item.oldText

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
            }

            if item.path then
                message.argument = FileSystem.to_smart_path(item.path)
            end

            return message
        end
    end

    local rawOutput = update.rawOutput
    if rawOutput then
        if rawOutput.stdout then
            message.body = self:safe_split(rawOutput.stdout)
        end

        if rawOutput.stderr then
            message.body = vim.list_extend(
                message.body or {},
                self:safe_split(rawOutput.stderr)
            )
        end
    end

    return message
end

--- @protected
--- @param message_id number
--- @param method string
--- @param params table
function CursorACPAdapter:__handle_notification(message_id, method, params)
    if method == "cursor/task" then
        -- cursor sent this AFTER the subagent was complete.
        -- it contains the prompt, model, and a brief description.
        -- silencing it for now
        -- it doesn't have any connection with a tool call like session id or tool call id
    else
        ACPClient.__handle_notification(self, message_id, method, params)
    end
end

--- Cursor can send tool call updates along the permission request
--- @class agentic.acp.CursorPermissionRequestToolCall : agentic.acp.ToolCall
--- @field status agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field kind agentic.acp.ToolKind

--- @protected
--- @param message_id number
--- @param request agentic.acp.RequestPermission
function CursorACPAdapter:__handle_request_permission(message_id, request)
    if request.toolCall then
        --- @class agentic.acp.ToolCallUpdate
        local update = vim.tbl_extend("force", request.toolCall, {
            sessionUpdate = "tool_call_update",
            sessionId = request.sessionId,
        })

        -- empty it for now, as it only contains a "not in allow list" message
        update.content = {}

        self:__handle_tool_call_update(request.sessionId, update)
    end

    ACPClient.__handle_request_permission(self, message_id, request)
end

return CursorACPAdapter
