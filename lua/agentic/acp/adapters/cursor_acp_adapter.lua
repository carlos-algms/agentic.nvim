local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")

--- Cursor-specific adapter that extends ACPClient with Cursor-specific behaviors
--- @class agentic.acp.CursorACPAdapter : agentic.acp.ACPClient
--- @field _available_commands_updates table<string, table> Cursor sends available commands before session starts, indexed by session ID, to be processed after session creation
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

    -- Initialize session-indexed storage for available commands
    self._available_commands_updates = {}

    return self
end

--- Overloading create_session to handle slash commands, as cursor sends them before session starts
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.acp.ACPError|nil)
function CursorACPAdapter:create_session(handlers, callback)
    --- @param result agentic.acp.SessionCreationResponse|nil
    --- @param err agentic.acp.ACPError|nil
    local function wrapped_callback(result, err)
        callback(result, err)

        if not err and result then
            local stored_update =
                self._available_commands_updates[result.sessionId]
            if stored_update then
                Logger.debug(
                    "CursorACPAdapter",
                    "Processing stored available commands update for session "
                        .. result.sessionId
                )
                self._available_commands_updates[result.sessionId] = nil
                self:__handle_session_update(stored_update)
            end
        end
    end

    ACPClient.create_session(self, handlers, wrapped_callback)
end

--- @param params table
function CursorACPAdapter:__handle_session_update(params)
    local type = params.update.sessionUpdate

    if type == "tool_call" then
        self:_handle_tool_call(params.sessionId, params.update)
    elseif type == "tool_call_update" then
        self:_handle_tool_call_update(params.sessionId, params.update)
    elseif type == "user_message_chunk" then
        -- Ignore user message chunks, otherwise it would duplicate messages in the Chat buffer
        return
    elseif type == "available_commands_update" then
        if not self.subscribers[params.sessionId] then
            Logger.debug(
                "CursorACPAdapter",
                "Storing available commands update for session "
                    .. params.sessionId
            )
            -- Store available commands update indexed by session ID
            self._available_commands_updates[params.sessionId] = params
        else
            ACPClient.__handle_session_update(self, params)
        end
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
