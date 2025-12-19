local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- Gemini-specific adapter that extends ACPClient with Gemini-specific behaviors
--- @class agentic.acp.GeminiACPAdapter : agentic.acp.ACPClient
local GeminiACPAdapter = setmetatable({}, { __index = ACPClient })
GeminiACPAdapter.__index = GeminiACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.GeminiACPAdapter
function GeminiACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, GeminiACPAdapter) --[[@as agentic.acp.GeminiACPAdapter]]

    return self
end

--- @param params table
function GeminiACPAdapter:__handle_session_update(params)
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
function GeminiACPAdapter:_handle_tool_call(session_id, update)
    local kind = update.kind

    if
        kind == "read"
        and (not update.locations or vim.tbl_isempty(update.locations))
    then
        -- gemini read file system and send empty properties, just ignore
        return
    end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "edit" then
        local content = update.content and update.content[1]

        if content then
            local new_string = content.newText or ""
            local old_string = content.oldText or ""

            message.diff = {
                new = vim.split(new_string, "\n"),
                old = vim.split(old_string, "\n"),
            }
        end

        local location = update.locations and update.locations[1]
        if location then
            message.argument = FileSystem.to_smart_path(location.path)
        end
    elseif kind == "execute" then
        --- Gemini "execute" title format:
        --- "command [context maybe path] (optional description)"
        message.argument = vim.trim(vim.split(update.title, " %[")[1] or "")

        local desc = update.title:match("%((.-)%)")
        if desc then
            message.body = vim.split(desc, "\n")
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function GeminiACPAdapter:_handle_tool_call_update(session_id, update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    if update.content and update.content[1] then
        local content = update.content[1]

        if content.type == "content" then
            message.body = content.content
                and vim.split(content.content.text, "\n")
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

--- Specific Gemini ToolCall structure - created to avoid confusion with the standard ACP types, as only Gemini sends these fields
--- @class agentic.acp.GeminiToolCall : agentic.acp.ToolCall
--- @field kind? agentic.acp.ToolKind
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field status? agentic.acp.ToolCallStatus
--- @field title? string

--- @class agentic.acp.GeminiRequestPermission : agentic.acp.RequestPermission
--- @field toolCall agentic.acp.GeminiToolCall

--- @protected
--- @param message_id number
--- @param request agentic.acp.GeminiRequestPermission
function GeminiACPAdapter:__handle_request_permission(message_id, request)
    -- Gemini asks for permission first, for edit, execute, etc,
    -- and sends diff block for the first time in the same message
    -- I have to intercept it, send a synthetic tool call, and then proceed with the normal flow

    local kind = request.toolCall.kind

    if kind == "edit" or kind == "execute" then
        local update = vim.tbl_extend("force", {
            sessionUpdate = "tool_call",
        }, request.toolCall) --[[@as agentic.acp.ToolCallMessage]]

        self:_handle_tool_call(request.sessionId, update)
    end

    -- Gemini also don't send "cancel" tool_call_update, so I have to generate a synthetic one
    local session_id = request.sessionId

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_request_permission(request, function(option_id)
            if option_id == "cancel" then
                --- @type agentic.acp.ToolCallUpdate
                local update = {
                    sessionUpdate = "tool_call_update",
                    toolCallId = request.toolCall.toolCallId,
                    status = "failed",
                }

                self:_handle_tool_call_update(session_id, update)
            end

            self:__send_result(
                message_id,
                { --- @type agentic.acp.RequestPermissionOutcome
                    outcome = {
                        outcome = "selected",
                        optionId = option_id,
                    },
                }
            )
        end)
    end)
end

return GeminiACPAdapter
