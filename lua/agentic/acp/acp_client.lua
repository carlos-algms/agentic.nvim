local Logger = require("agentic.utils.logger")
local transport_module = require("agentic.acp.acp_transport")
local FileSystem = require("agentic.utils.file_system")

--[[
CRITICAL: Type annotations in this file are essential for Lua Language Server support.
DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- Known ACP protocol tool call kinds.
--- Used to detect unknown kinds from providers we don't use daily.
local KNOWN_ACP_KINDS = {
    read = true,
    edit = true,
    delete = true,
    move = true,
    search = true,
    execute = true,
    think = true,
    fetch = true,
    other = true,
    create = true,
    switch_mode = true,
}

--- Data fields set in the constructor. Separated from the full class
--- so LuaLS validates instance fields without requiring methods that
--- live on the prototype via __index.
--- @class agentic.acp.ACPClientData
--- @field provider_config agentic.acp.ACPProviderConfig
--- @field id_counter number
--- @field state agentic.acp.ClientConnectionState
--- @field protocol_version number
--- @field client_info agentic.acp.ClientInfo
--- @field capabilities agentic.acp.ClientCapabilities
--- @field agent_capabilities? agentic.acp.AgentCapabilities
--- @field callbacks table<number, fun(result: table|nil, err: agentic.acp.ACPError|nil)>
--- @field transport? agentic.acp.ACPTransportInstance
--- @field subscribers table<string, agentic.acp.ClientHandlers>

--- @class agentic.acp.ACPClient : agentic.acp.ACPClientData
--- @field _on_ready fun(client: agentic.acp.ACPClient)
local ACPClient = {}
ACPClient.__index = ACPClient

--- ACP Error codes
ACPClient.ERROR_CODES = {
    TRANSPORT_ERROR = -32000,
    PROTOCOL_ERROR = -32001,
    TIMEOUT_ERROR = -32002,
    AUTH_REQUIRED = -32003,
    SESSION_NOT_FOUND = -32004,
    PERMISSION_DENIED = -32005,
    INVALID_REQUEST = -32006,
}

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ACPClient
function ACPClient:new(config, on_ready)
    --- @type agentic.acp.ACPClientData
    local instance = {
        provider_config = config,
        subscribers = {},
        id_counter = 0,
        protocol_version = 1,
        client_info = {
            name = "Agentic.nvim",
            version = "0.0.1",
        },
        capabilities = {
            fs = {
                readTextFile = true,
                writeTextFile = true,
            },
            terminal = false,
        },
        callbacks = {},
        transport = nil,
        state = "disconnected",
        reconnect_count = 0,
    }

    local client = setmetatable(instance, self) --[[@as agentic.acp.ACPClient]]
    client._on_ready = on_ready

    client:_setup_transport()
    client:_connect()
    return client
end

--- @param session_id string
--- @param handlers agentic.acp.ClientHandlers
function ACPClient:_subscribe(session_id, handlers)
    self.subscribers[session_id] = handlers
end

--- @protected
--- @param session_id string
--- @param callback fun(sub: agentic.acp.ClientHandlers): nil
function ACPClient:__with_subscriber(session_id, callback)
    local subscriber = self.subscribers[session_id]

    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        callback(subscriber)
    end)
end

function ACPClient:_setup_transport()
    local transport_type = self.provider_config.transport_type or "stdio"

    if transport_type == "stdio" then
        --- @type agentic.acp.StdioTransportConfig
        local transport_config = {
            command = self.provider_config.command,
            args = self.provider_config.args,
            env = self.provider_config.env,
            enable_reconnect = self.provider_config.reconnect,
            max_reconnect_attempts = self.provider_config.max_reconnect_attempts,
        }

        --- @type agentic.acp.TransportCallbacks
        local callbacks = {
            on_state_change = function(state)
                self:_set_state(state)
            end,
            on_message = function(message)
                self:_handle_message(message)
            end,
            on_reconnect = function()
                if self.state == "disconnected" then
                    self:_connect()
                end
            end,
            get_reconnect_count = function()
                return self.reconnect_count
            end,
            increment_reconnect_count = function()
                self.reconnect_count = self.reconnect_count + 1
            end,
        }

        self.transport =
            transport_module.create_stdio_transport(transport_config, callbacks)
    else
        error("Unsupported transport type: " .. transport_type)
    end
end

--- @param state agentic.acp.ClientConnectionState
function ACPClient:_set_state(state)
    self.state = state
end

--- @protected
--- @param code number
--- @param message string
--- @param data any|nil
--- @return agentic.acp.ACPError
function ACPClient:__create_error(code, message, data)
    return {
        code = code,
        message = message,
        data = data,
    }
end

--- @return number
function ACPClient:_next_id()
    self.id_counter = self.id_counter + 1
    return self.id_counter
end

--- @param method string
--- @param params table|nil
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:_send_request(method, params, callback)
    local id = self:_next_id()
    local message = {
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params or {},
    }

    self.callbacks[id] = callback

    local data = vim.json.encode(message)

    Logger.debug_to_file("request: ", message)

    self.transport:send(data)
end

--- @param method string
--- @param params table|nil
function ACPClient:_send_notification(method, params)
    local message = {
        jsonrpc = "2.0",
        method = method,
        params = params or {},
    }

    local data = vim.json.encode(message)

    Logger.debug_to_file("notification: ", message, "\n\n")

    self.transport:send(data)
end

--- @protected
--- @param id number
--- @param result table | string | vim.NIL | nil
--- @return nil
function ACPClient:__send_result(id, result)
    local message = { jsonrpc = "2.0", id = id, result = result }

    local data = vim.json.encode(message)
    Logger.debug_to_file("request:", message)

    self.transport:send(data)
end

--- @param id number
--- @param message string
--- @param code number|nil
--- @return nil
function ACPClient:_send_error(id, message, code)
    code = code or self.ERROR_CODES.TRANSPORT_ERROR
    local msg =
        { jsonrpc = "2.0", id = id, error = { code = code, message = message } }

    local data = vim.json.encode(msg)
    self.transport:send(data)
end

--- Handles raw JSON-RPC message received from the transport
--- @param message agentic.acp.ResponseRaw
function ACPClient:_handle_message(message)
    -- NOT log agent messages chunk to avoid huge logs file
    if
        not (
            message.params
            and message.params.update
            and (
                message.params.update.sessionUpdate == "agent_message_chunk"
                or message.params.update.sessionUpdate
                    == "agent_thought_chunk"
            )
        )
    then
        Logger.debug_to_file(self.provider_config.name, "response: ", message)
    end

    -- Check if this is a notification (has method but no id, or has both method and id for notifications)
    if message.method and not message.result and not message.error then
        -- This is a notification
        self:_handle_notification(message.id, message.method, message.params)
    elseif message.id and (message.result or message.error) then
        local callback = self.callbacks[message.id]
        if callback then
            self.callbacks[message.id] = nil
            callback(message.result, message.error)
        else
            Logger.notify(
                "No callback found for response id: "
                    .. tostring(message.id)
                    .. "\n\n"
                    .. vim.inspect(message)
            )
        end
    else
        Logger.notify("Unknown message type: " .. vim.inspect(message))
    end
end

--- @param message_id number
--- @param method string
--- @param params table
function ACPClient:_handle_notification(message_id, method, params)
    if method == "session/update" then
        self:__handle_session_update(params)
    elseif method == "session/request_permission" then
        --- @diagnostic disable-next-line: param-type-mismatch
        self:__handle_request_permission(message_id, params)
    elseif method == "fs/read_text_file" then
        self:_handle_read_text_file(message_id, params)
    elseif method == "fs/write_text_file" then
        self:_handle_write_text_file(message_id, params)
    else
        Logger.notify("Unknown notification method: " .. method)
    end
end

--- @protected
--- @param params table
function ACPClient:__handle_session_update(params)
    local session_id = params.sessionId
    local update = params.update

    if not session_id then
        Logger.notify("Received session/update without sessionId")
        return
    end

    if not update then
        Logger.notify("Received session/update without update data")
        return
    end

    local session_update_type = update.sessionUpdate

    if session_update_type == "tool_call" then
        if not KNOWN_ACP_KINDS[update.kind] then
            -- Using notify intentionally so users of providers
            -- we don't use daily report unknown kinds as issues
            Logger.notify(
                "Unknown ACP tool call kind: "
                    .. tostring(update.kind)
                    .. "\n\n"
                    .. "Please report this so we can add support for it!\n\n"
                    .. "https://github.com/carlos-algms/agentic.nvim/issues/new",
                vim.log.levels.WARN
            )
        end

        self:__handle_tool_call(session_id, update)
    elseif session_update_type == "tool_call_update" then
        self:__handle_tool_call_update(session_id, update)
    else
        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_session_update(update)
        end)
    end
end

--- Extract body text from standard ACP content field.
--- Adapters should use this to avoid duplicating content extraction logic.
--- @param update agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate
--- @return string[]|nil body
function ACPClient:extract_content_body(update)
    local content = update.content and update.content[1]

    if
        content
        and content.type == "content"
        and content.content
        and content.content.text
    then
        return self:safe_split(content.content.text)
    end

    return nil
end

--- Safely split a string into an array of lines
--- Some agents send `nil` other send `vim.NIL` for empty content
--- @param possible_string string|nil|vim.NIL
--- @return string[] lines
function ACPClient:safe_split(possible_string)
    if type(possible_string) == "string" then
        return vim.split(possible_string, "\n")
    end

    return {}
end

--- Build the message for a tool_call. it's usually the first update received for a tool call
--- Adapters override this to add provider-specific fields or transformations.
--- @protected
--- @param update agentic.acp.ToolCallMessage
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function ACPClient:__build_tool_call_message(update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind,
        status = update.status,
        argument = update.title,
        body = self:extract_content_body(update),
    }

    return message
end

--- Default handler for tool_call session updates.
--- Builds a generic ToolCallBlock from standard ACP fields.
--- Adapters override this for provider-specific transformations.
--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function ACPClient:__handle_tool_call(session_id, update)
    local message = self:__build_tool_call_message(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Build the message for a tool_call_update.
--- Adapters override this to add provider-specific fields.
--- @protected
--- @param update agentic.acp.ToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function ACPClient:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
    }
    return message
end

--- Default handler for tool_call_update session updates.
--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function ACPClient:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    local message = self:__build_tool_call_update(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

--- @protected
--- @param message_id number
--- @param request agentic.acp.RequestPermission
function ACPClient:__handle_request_permission(message_id, request)
    if not request.sessionId or not request.toolCall then
        error("Invalid request_permission")
        return
    end

    local session_id = request.sessionId

    self:__with_subscriber(session_id, function(subscriber)
        -- Every change to this block MUST be reflected in Gemini's ACP Adapter, as it has custom implementation @see gemini_acp_adapter.lua
        subscriber.on_request_permission(request, function(option_id)
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

--- @param message_id number
--- @param params table
function ACPClient:_handle_read_text_file(message_id, params)
    local session_id = params.sessionId
    local path = params.path

    if not session_id or not path then
        Logger.notify("Received fs/read_text_file without sessionId or path")
        return
    end

    self:__with_subscriber(session_id, function()
        FileSystem.read_file(
            path,
            params.line ~= vim.NIL and params.line or nil,
            params.limit ~= vim.NIL and params.limit or nil,
            function(content)
                self:__send_result(message_id, { content = content })
            end
        )
    end)
end

--- @param message_id number
--- @param params table
function ACPClient:_handle_write_text_file(message_id, params)
    local session_id = params.sessionId
    local path = params.path
    local content = params.content

    if not session_id or not path or not content then
        Logger.notify(
            "Received fs/write_text_file without sessionId, path, or content"
        )
        return
    end

    self:__with_subscriber(session_id, function()
        FileSystem.write_file(path, content, function(error)
            self:__send_result(message_id, error == nil and vim.NIL or error)
        end)
    end)
end

function ACPClient:stop()
    self.transport:stop()
end

function ACPClient:_connect()
    if self.state ~= "disconnected" then
        return
    end

    self.transport:start()

    if self.state ~= "connected" then
        local error = self:__create_error(
            self.ERROR_CODES.PROTOCOL_ERROR,
            "Cannot initialize: client not connected"
        )
        return error
    end

    self:_set_state("initializing")

    --- @type agentic.acp.InitializeParams
    local init_params = {
        protocolVersion = self.protocol_version,
        clientInfo = self.client_info,
        clientCapabilities = self.capabilities,
    }

    self:_send_request("initialize", init_params, function(result, err)
        if not result or err then
            self:_set_state("error")
            Logger.notify(
                "Failed to initialize\n\n" .. vim.inspect(err),
                vim.log.levels.ERROR
            )
            return
        end

        self.protocol_version = result.protocolVersion
        self.agent_capabilities = result.agentCapabilities
        self.auth_methods = result.authMethods or {}

        -- Check if we need to authenticate
        local auth_method = self.provider_config.auth_method

        -- FIXIT: auth_method should be validated against available methods from the agent message
        -- Claude reports auth methods but it returns no-implemented error when trying to authenticate with any method
        if auth_method then
            Logger.debug("Authenticating with method ", auth_method)
            self:_authenticate(auth_method)
        else
            Logger.debug("No authentication method found or specified")
            self:_set_state("ready")
            self._on_ready(self)
        end
    end)
end

--- TODO: Authentication is NOT implemented properly yet by the ACP providers, revisit this later
---
--- @param method_id string
function ACPClient:_authenticate(method_id)
    self:_send_request("authenticate", {
        methodId = method_id,
    }, function()
        self:_set_state("ready")
        self._on_ready(self)
    end)
end

--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.acp.ACPError|nil)
function ACPClient:create_session(handlers, callback)
    local cwd = vim.fn.getcwd()

    self:_send_request("session/new", {
        cwd = cwd,
        mcpServers = {},
    }, function(result, err)
        if err then
            Logger.notify(
                "Failed to create session: "
                    .. (err.message or vim.inspect(err)),
                vim.log.levels.ERROR,
                { title = "🐞 Session creation error" }
            )

            callback(nil, err)
            return
        end

        if not result then
            err = self:__create_error(
                self.ERROR_CODES.PROTOCOL_ERROR,
                "Failed to create session: missing result"
            )

            callback(nil, err)
            return
        end

        if result.sessionId then
            self:_subscribe(result.sessionId, handlers)
        end

        --- @cast result agentic.acp.SessionCreationResponse
        callback(result, nil)
    end)
end

--- @param session_id string
--- @param cwd string
--- @param mcp_servers table[]|nil
--- @param handlers agentic.acp.ClientHandlers
function ACPClient:load_session(session_id, cwd, mcp_servers, handlers)
    --FIXIT: check if it's possible to ignore this check and just try to send load message
    -- handle the response error properly also
    if
        not self.agent_capabilities or not self.agent_capabilities.loadSession
    then
        Logger.notify("Agent does not support loading sessions")
        return
    end

    self:_subscribe(session_id, handlers)

    self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
    }, function()
        -- no-op
    end)
end

--- @param session_id string
--- @param prompt agentic.acp.Content[]
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
    local params = {
        sessionId = session_id,
        prompt = prompt,
    }

    return self:_send_request("session/prompt", params, callback)
end

--- Set the agent mode for a session
--- @param session_id string
--- @param mode_id string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_mode(session_id, mode_id, callback)
    local params = {
        sessionId = session_id,
        modeId = mode_id,
    }
    return self:_send_request("session/set_mode", params, callback)
end

--- Stops current generation/tool execution, keeps session active for the next prompt
--- @param session_id string
function ACPClient:stop_generation(session_id)
    if not session_id then
        return
    end

    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- Cancels and destroys session (cleanup)
--- Either to create a new session or if the tabpage is closed
--- @param session_id string
function ACPClient:cancel_session(session_id)
    if not session_id then
        return
    end

    -- remove subscriber first to avoid handling any further messages
    self.subscribers[session_id] = nil

    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- @return boolean
function ACPClient:is_connected()
    return self.state ~= "disconnected" and self.state ~= "error"
end

return ACPClient

--- @class agentic.acp.ClientInfo
--- @field name string
--- @field version string

--- @class agentic.acp.ClientCapabilities
--- @field fs agentic.acp.FileSystemCapability
--- @field terminal boolean

--- @class agentic.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo agentic.acp.ClientInfo
--- @field clientCapabilities agentic.acp.ClientCapabilities

--- @class agentic.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class agentic.acp.AgentCapabilities
--- @field loadSession boolean
--- @field promptCapabilities agentic.acp.PromptCapabilities

--- @class agentic.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class agentic.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env agentic.acp.EnvVariable[]

--- @class agentic.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias agentic.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias agentic.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "WebSearch"
--- | "SlashCommand"
--- | "SubAgent"
--- | "other"
--- | "create"
--- | "Skill"
--- | "switch_mode"

--- @alias agentic.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias agentic.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias agentic.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class agentic.acp.RawInput
--- @field file_path string
--- @field new_string? string
--- @field old_string? string
--- @field replace_all? boolean
--- @field description? string
--- @field command? string
--- @field url? string Usually from the fetch tool
--- @field prompt? string Usually accompanying the fetch tool, not the web_search
--- @field query? string Usually from the web_search tool
--- @field timeout? number

--- @class agentic.acp.ToolCall
--- @field toolCallId string
--- @field rawInput? agentic.acp.RawInput

--- @class agentic.acp.ToolCallRegularContent
--- @field type "content"
--- @field content agentic.acp.Content

--- @class agentic.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText string
--- @field newText string

--- @alias agentic.acp.ACPToolCallContent
--- | agentic.acp.ToolCallRegularContent
--- | agentic.acp.ToolCallDiffContent

--- @class agentic.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class agentic.acp.PlanEntry
--- @field content string
--- @field priority agentic.acp.PlanEntryPriority
--- @field status agentic.acp.PlanEntryStatus

--- @class agentic.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class agentic.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class agentic.acp.ModesInfo
--- @field availableModes agentic.acp.AgentMode[]
--- @field currentModeId string

--- @class agentic.acp.ModelsInfo
--- @field availableModels agentic.acp.Model[]
--- @field currentModelId string

--- @class agentic.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? agentic.acp.ModesInfo
--- @field models? agentic.acp.ModelsInfo

--- @class agentic.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method string
--- @field result? table
--- @field params? { sessionId: string, update: agentic.acp.SessionUpdateMessage }
--- @field error? agentic.acp.ACPError

--- @class agentic.acp.ToolCallMessage
--- @field sessionUpdate "tool_call"
--- @field toolCallId string
--- @field title string most likely the command to be executed
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawInput? agentic.acp.RawInput

--- @class agentic.acp.ToolCallUpdate
--- @field sessionUpdate "tool_call_update"
--- @field toolCallId string
--- @field status? agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field rawOutput? table Not all providers are sending it, seems non standard

--- @class agentic.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries agentic.acp.PlanEntry[]

--- @class agentic.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands agentic.acp.AvailableCommand[]

--- @class agentic.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class agentic.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @alias agentic.acp.SessionUpdateMessage
--- | agentic.acp.UserMessageChunk
--- | agentic.acp.AgentMessageChunk
--- | agentic.acp.AgentThoughtChunk
--- | agentic.acp.ToolCallMessage
--- | agentic.acp.ToolCallUpdate
--- | agentic.acp.PlanUpdate
--- | agentic.acp.AvailableCommandsUpdate
--- | agentic.acp.CurrentModeUpdate
--- | agentic.acp.UsageUpdate

--- @class agentic.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- @class agentic.acp.RequestPermission
--- @field options agentic.acp.PermissionOption[]
--- @field sessionId string
--- @field toolCall agentic.acp.ToolCall

--- @class agentic.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias agentic.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class agentic.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage): nil
--- @alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias agentic.acp.ClientHandlers.on_error fun(err: agentic.acp.ACPError): nil

--- @class agentic.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.acp.ClientHandlers
--- @field on_session_update agentic.acp.ClientHandlers.on_session_update
--- @field on_request_permission agentic.acp.ClientHandlers.on_request_permission
--- @field on_error agentic.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBase): nil

--- @class agentic.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? agentic.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
