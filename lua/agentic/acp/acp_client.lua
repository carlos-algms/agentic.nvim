local Logger = require("agentic.utils.logger")
local transport_module = require("agentic.acp.acp_transport")
local FileSystem = require("agentic.utils.file_system")

---@class agentic.acp.ACPClient
---@field provider_config agentic.acp.ClientConfig
---@field id_counter number
---@field state agentic.acp.ClientConnectionState
---@field protocol_version number
---@field capabilities agentic.acp.ClientCapabilities
---@field agent_capabilities? agentic.acp.AgentCapabilities
---@field callbacks table<number, fun(result?: table, err?: agentic.acp.ACPError)>
---@field transport? agentic.acp.ACPTransportInstance
---@field subscribers table<string, agentic.acp.ClientHandlers>
local ACPClient = {}

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

---@param config agentic.acp.ClientConfig
---@return agentic.acp.ACPClient
function ACPClient:new(config)
    ---@type agentic.acp.ACPClient
    local instance = {
        provider_config = config,
        subscribers = {},
        id_counter = 0,
        protocol_version = 1,
        capabilities = {
            fs = {
                readTextFile = true,
                writeTextFile = true,
            },
            terminal = false,
            clientInfo = {
                name = "Agentic.nvim",
                version = "0.0.1",
            },
        },
        callbacks = {},
        transport = nil,
        state = "disconnected",
        reconnect_count = 0,
    }

    local client = setmetatable(instance, { __index = self }) --[[@as agentic.acp.ACPClient]]

    client:_setup_transport()
    client:_connect()
    return client
end

---@param session_id string
---@param handlers agentic.acp.ClientHandlers
function ACPClient:_subscribe(session_id, handlers)
    self.subscribers[session_id] = handlers
end

---@param session_id string
---@return agentic.acp.ClientHandlers|nil
function ACPClient:_get_subscriber(session_id)
    return self.subscribers[session_id]
end

function ACPClient:_setup_transport()
    local transport_type = self.provider_config.transport_type or "stdio"

    if transport_type == "stdio" then
        ---@type agentic.acp.StdioTransportConfig
        local transport_config = {
            command = self.provider_config.command,
            args = self.provider_config.args,
            env = self.provider_config.env,
            enable_reconnect = self.provider_config.reconnect,
            max_reconnect_attempts = self.provider_config.max_reconnect_attempts,
        }

        ---@type agentic.acp.TransportCallbacks
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

---@param state agentic.acp.ClientConnectionState
function ACPClient:_set_state(state)
    self.state = state
end

---@param code number
---@param message string
---@param data any?
---@return agentic.acp.ACPError
function ACPClient:_create_error(code, message, data)
    return {
        code = code,
        message = message,
        data = data,
    }
end

---@return number
function ACPClient:_next_id()
    self.id_counter = self.id_counter + 1
    return self.id_counter
end

---@param method string
---@param params? table
---@param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
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

---@param method string
---@param params table?
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

---@param id number
---@param result table | string | vim.NIL | nil
---@return nil
function ACPClient:_send_result(id, result)
    local message = { jsonrpc = "2.0", id = id, result = result }

    local data = vim.json.encode(message)
    Logger.debug_to_file("request:", message)

    self.transport:send(data)
end

---@param id number
---@param message string
---@param code? number
---@return nil
function ACPClient:_send_error(id, message, code)
    code = code or self.ERROR_CODES.TRANSPORT_ERROR
    local msg =
        { jsonrpc = "2.0", id = id, error = { code = code, message = message } }

    local data = vim.json.encode(msg)
    self.transport:send(data)
end

---Handles raw JSON-RPC message received from the transport
---@param message table
function ACPClient:_handle_message(message)
    Logger.debug_to_file("response: ", message)

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
            vim.notify(
                "No callback found for response id: "
                    .. tostring(message.id)
                    .. "\n\n"
                    .. vim.inspect(message),
                vim.log.levels.WARN
            )
        end
    else
        vim.notify(
            "Unknown message type: " .. vim.inspect(message),
            vim.log.levels.WARN
        )
    end
end

---@param method string
---@param params table
function ACPClient:_handle_notification(message_id, method, params)
    if method == "session/update" then
        self:_handle_session_update(params)
    elseif method == "session/request_permission" then
        ---@diagnostic disable-next-line: param-type-mismatch
        self:_handle_request_permission(message_id, params)
    elseif method == "fs/read_text_file" then
        self:_handle_read_text_file(message_id, params)
    elseif method == "fs/write_text_file" then
        self:_handle_write_text_file(message_id, params)
    else
        vim.notify(
            "Unknown notification method: " .. method,
            vim.log.levels.WARN
        )
    end
end

---@param params table
function ACPClient:_handle_session_update(params)
    local session_id = params.sessionId
    local update = params.update

    if not session_id then
        vim.notify(
            "Received session/update without sessionId",
            vim.log.levels.WARN
        )
        return
    end

    if not update then
        vim.notify(
            "Received session/update without update data",
            vim.log.levels.WARN
        )
        return
    end

    local subscriber = self:_get_subscriber(session_id)
    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        subscriber.on_session_update(update)
    end)
end

---@param message_id number
---@param request agentic.acp.RequestPermission
function ACPClient:_handle_request_permission(message_id, request)
    if not request.sessionId or not request.toolCall then
        error("Invalid request_permission")
        return
    end

    local session_id = request.sessionId
    local subscriber = self:_get_subscriber(session_id)
    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        subscriber.on_request_permission(request, function(option_id)
            self:_send_result(
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

---@param message_id number
---@param params table
function ACPClient:_handle_read_text_file(message_id, params)
    local session_id = params.sessionId
    local path = params.path

    if not session_id or not path then
        vim.notify(
            "Received fs/read_text_file without sessionId or path",
            vim.log.levels.WARN
        )
        return
    end

    local subscriber = self:_get_subscriber(session_id)
    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        subscriber.on_read_file(
            path,
            params.line ~= vim.NIL and params.line or nil,
            params.limit ~= vim.NIL and params.limit or nil,
            function(content)
                self:_send_result(message_id, { content = content })
            end
        )
    end)
end

---@param message_id number
---@param params table
function ACPClient:_handle_write_text_file(message_id, params)
    local session_id = params.sessionId
    local path = params.path
    local content = params.content

    if not session_id or not path or not content then
        vim.notify(
            "Received fs/write_text_file without sessionId, path, or content",
            vim.log.levels.WARN
        )
        return
    end

    local subscriber = self:_get_subscriber(session_id)
    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    vim.schedule(function()
        subscriber.on_write_file(path, content, function(error)
            self:_send_result(message_id, error == nil and vim.NIL or error)
        end)
    end)
end

function ACPClient:_connect()
    if self.state ~= "disconnected" then
        return
    end

    self.transport:start()

    self:_initialize()
end

function ACPClient:stop()
    self.transport:stop()
end

function ACPClient:_initialize()
    if self.state ~= "connected" then
        local error = self:_create_error(
            self.ERROR_CODES.PROTOCOL_ERROR,
            "Cannot initialize: client not connected"
        )
        return error
    end

    self:_set_state("initializing")

    self:_send_request("initialize", {
        protocolVersion = self.protocol_version,
        clientCapabilities = self.capabilities,
    }, function(result, err)
        if not result or err then
            self:_set_state("error")
            vim.notify(
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
        if auth_method then
            Logger.debug("Authenticating with method ", auth_method)
            self:_authenticate(auth_method)
        else
            Logger.debug("No authentication method found or specified")
            self:_set_state("ready")
        end
    end)
end

---@param method_id string
function ACPClient:_authenticate(method_id)
    self:_send_request("authenticate", {
        methodId = method_id,
    }, function()
        self:_set_state("ready")
    end)
end

---@param handlers agentic.acp.ClientHandlers
---@param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:create_session(handlers, callback)
    local cwd = vim.fn.getcwd()

    self:_send_request("session/new", {
        cwd = cwd,
        mcpServers = {},
    }, function(result, err)
        callback = callback or function() end
        if err then
            vim.notify(
                "Failed to create session: " .. err.message,
                vim.log.levels.ERROR
            )
            callback(nil, err)
            return
        end

        if not result then
            err = self:_create_error(
                self.ERROR_CODES.PROTOCOL_ERROR,
                "Failed to create session: missing result"
            )

            callback(nil, err)
            return
        end

        if result.sessionId then
            self:_subscribe(result.sessionId, handlers)
        end

        callback(result, err)
    end)
end

---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@param handlers agentic.acp.ClientHandlers
function ACPClient:load_session(session_id, cwd, mcp_servers, handlers)
    --FIXIT: check if it's possible to ignore this check and just try to send load message
    -- handle the response error properly also
    if
        not self.agent_capabilities or not self.agent_capabilities.loadSession
    then
        vim.notify(
            "Agent does not support loading sessions",
            vim.log.levels.WARN
        )
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

---@param session_id string
---@param prompt agentic.acp.Content[]
---@param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
    local params = {
        sessionId = session_id,
        prompt = prompt,
    }

    return self:_send_request("session/prompt", params, callback)
end

---@param session_id string
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

---@return boolean
function ACPClient:is_connected()
    return self.state ~= "disconnected" and self.state ~= "error"
end

---@param text string|table
---@return agentic.acp.UserMessageChunk
function ACPClient:generate_user_message(text)
    return self:_generate_message_chunk(text, "user_message_chunk") --[[@as agentic.acp.UserMessageChunk]]
end

---@param text string|table
---@return agentic.acp.AgentMessageChunk
function ACPClient:generate_agent_message(text)
    return self:_generate_message_chunk(text, "agent_message_chunk") --[[@as agentic.acp.AgentMessageChunk]]
end

---@param text string|table
---@param role "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"
function ACPClient:_generate_message_chunk(text, role)
    local content_text

    if type(text) == "string" then
        content_text = text
    elseif type(text) == "table" then
        content_text = table.concat(text, "\n")
    else
        content_text = vim.inspect(text)
    end

    return { ---@type agentic.acp.UserMessageChunk|agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
        sessionUpdate = role,
        content = {
            type = "text",
            text = content_text,
        },
    }
end

---@param path string
---@param text string
---@param annotations? agentic.acp.Annotations
---@return agentic.acp.ResourceContent
function ACPClient:create_resource_content(path, text, annotations)
    local uri = "file://" .. FileSystem.to_absolute_path(path)

    ---@type agentic.acp.ResourceContent
    local resource = {
        type = "resource",
        resource = {
            uri = uri,
            text = text,
        },
        annotations = annotations,
    }

    return resource
end

---@param path string
---@param annotations? agentic.acp.Annotations
---@return agentic.acp.ResourceLinkContent
function ACPClient:create_resource_link_content(path, annotations)
    local uri = "file://" .. FileSystem.to_absolute_path(path)
    local name = FileSystem.base_name(path)

    ---@type agentic.acp.ResourceLinkContent
    local resource = {
        type = "resource_link",
        uri = uri,
        name = name,
        annotations = annotations,
    }

    return resource
end

return ACPClient

---@class agentic.acp.ClientCapabilities
---@field fs agentic.acp.FileSystemCapability
---@field terminal boolean
---@field clientInfo { name: string, version: string }

---@class agentic.acp.FileSystemCapability
---@field readTextFile boolean
---@field writeTextFile boolean

---@class agentic.acp.AgentCapabilities
---@field loadSession boolean
---@field promptCapabilities agentic.acp.PromptCapabilities

---@class agentic.acp.PromptCapabilities
---@field image boolean
---@field audio boolean
---@field embeddedContext boolean

---@class agentic.acp.AuthMethod
---@field id string
---@field name string
---@field description? string

---@class agentic.acp.McpServer
---@field name string
---@field command string
---@field args string[]
---@field env agentic.acp.EnvVariable[]

---@class agentic.acp.EnvVariable
---@field name string
---@field value string

---@alias agentic.acp.StopReason "end_turn" | "max_tokens" | "max_turn_requests" | "refusal" | "cancelled"

---@alias agentic.acp.ToolKind "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other"

---@alias agentic.acp.ToolCallStatus "pending" | "in_progress" | "completed" | "failed"

---@alias agentic.acp.PlanEntryStatus "pending" | "in_progress" | "completed"

---@alias agentic.acp.PlanEntryPriority "high" | "medium" | "low"

---@class agentic.acp.TextContent
---@field type "text"
---@field text string
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.ImageContent
---@field type "image"
---@field data string
---@field mimeType string
---@field uri? string
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.AudioContent
---@field type "audio"
---@field data string
---@field mimeType string
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.ResourceLinkContent
---@field type "resource_link"
---@field uri string
---@field name string
---@field description? string
---@field mimeType? string
---@field size? number
---@field title? string
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.ResourceContent
---@field type "resource"
---@field resource agentic.acp.EmbeddedResource
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.EmbeddedResource
---@field uri string
---@field text string
---@field blob? string
---@field mimeType? string

---@alias agentic.acp.Annotations.Audience "user" | "assistant"

---@class agentic.acp.Annotations
---@field audience? agentic.acp.Annotations.Audience[]
---@field lastModified? string
---@field priority? number

---@alias agentic.acp.Content
--- | agentic.acp.TextContent
--- | agentic.acp.ImageContent
--- | agentic.acp.AudioContent
--- | agentic.acp.ResourceLinkContent
--- | agentic.acp.ResourceContent

---@class agentic.acp.RawInput
---@field file_path string
---@field new_string? string
---@field old_string? string
---@field replace_all? boolean
---@field description? string
---@field command? string
---@field url? string Usually from the fetch tool
---@field prompt? string Usually accompanying the fetch tool, not the web_search
---@field query? string Usually from the web_search tool
---@field timeout? number

---@class agentic.acp.ToolCall
---@field toolCallId string
---@field rawInput? agentic.acp.RawInput
---

---@class agentic.acp.ToolCallRegularContent
---@field type "content"
---@field content agentic.acp.Content

---@class agentic.acp.ToolCallDiffContent
---@field type "diff"
---@field path string
---@field oldText string
---@field newText string

---@alias agentic.acp.ACPToolCallContent agentic.acp.ToolCallRegularContent | agentic.acp.ToolCallDiffContent

---@class agentic.acp.ToolCallLocation
---@field path string
---@field line? number

---@class agentic.acp.PlanEntry
---@field content string
---@field priority agentic.acp.PlanEntryPriority
---@field status agentic.acp.PlanEntryStatus

---@class agentic.acp.Plan
---@field entries agentic.acp.PlanEntry[]

---@class agentic.acp.AvailableCommand
---@field name string
---@field description string
---@field input? table<string, any>

---@class agentic.acp.UserMessageChunk
---@field sessionUpdate "user_message_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.AgentMessageChunk
---@field sessionUpdate "agent_message_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.AgentThoughtChunk
---@field sessionUpdate "agent_thought_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.ToolCallMessage
---@field sessionUpdate "tool_call"
---@field toolCallId string
---@field title? string most likely the command to be executed
---@field kind? agentic.acp.ToolKind
---@field status agentic.acp.ToolCallStatus
---@field content? agentic.acp.ACPToolCallContent[]
---@field locations? agentic.acp.ToolCallLocation[]
---@field rawInput? agentic.acp.RawInput
---@field rawOutput? table

---@class agentic.acp.ToolCallUpdate
---@field sessionUpdate "tool_call_update"
---@field status agentic.acp.ToolCallStatus
---@field content agentic.acp.ACPToolCallContent[]
---@field toolCallId string

---@class agentic.acp.PlanUpdate
---@field sessionUpdate "plan"
---@field entries agentic.acp.PlanEntry[]

---@class agentic.acp.AvailableCommandsUpdate
---@field sessionUpdate "available_commands_update"
---@field availableCommands agentic.acp.AvailableCommand[]

---@alias agentic.acp.SessionUpdateMessage
--- | agentic.acp.UserMessageChunk
--- | agentic.acp.AgentMessageChunk
--- | agentic.acp.AgentThoughtChunk
--- | agentic.acp.ToolCallMessage
--- | agentic.acp.ToolCallUpdate
--- | agentic.acp.PlanUpdate
--- | agentic.acp.AvailableCommandsUpdate

---@class agentic.acp.PermissionOption
---@field optionId string
---@field name string
---@field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

---@class agentic.acp.RequestPermission
---@field options agentic.acp.PermissionOption[]
---@field sessionId string
---@field toolCall agentic.acp.ToolCall

---@class agentic.acp.RequestPermissionOutcome
---@field outcome "cancelled" | "selected"
---@field optionId? string

---@alias agentic.acp.ClientConnectionState "disconnected" | "connecting" | "connected" | "initializing" | "ready" | "error"

---@class agentic.acp.ACPError
---@field code number
---@field message string
---@field data? any

---@alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage): nil
---@alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
---@alias agentic.acp.ClientHandlers.on_read_file fun(path: string, line: integer | nil, limit: integer | nil, callback: fun(content: string|nil)): nil
---@alias agentic.acp.ClientHandlers.on_write_file fun(path: string, content: string, callback: fun(error: string|nil)): nil
---@alias agentic.acp.ClientHandlers.on_error fun(err: agentic.acp.ACPError): nil

---@class agentic.Selection
---@field lines string[] The selected code lines
---@field start_line integer Starting line number (1-indexed)
---@field end_line integer Ending line number (1-indexed, inclusive)
---@field file_path string Relative file path
---@field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
---@class agentic.acp.ClientHandlers
---@field on_session_update agentic.acp.ClientHandlers.on_session_update
---@field on_request_permission agentic.acp.ClientHandlers.on_request_permission
---@field on_read_file agentic.acp.ClientHandlers.on_read_file
---@field on_write_file agentic.acp.ClientHandlers.on_write_file
---@field on_error agentic.acp.ClientHandlers.on_error

---@class agentic.acp.ClientConfig
---@field transport_type? agentic.acp.TransportType
---@field command? string Command to spawn agent (for stdio)
---@field args? string[] Arguments for agent command
---@field env? table<string, string> Environment variables
---@field timeout? number Request timeout in milliseconds
---@field reconnect? boolean Enable auto-reconnect
---@field max_reconnect_attempts? number Maximum reconnection attempts
---@field auth_method? string Authentication method
