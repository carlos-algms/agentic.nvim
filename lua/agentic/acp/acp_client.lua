local logger = require("agentic.utils.logger")
local uv = vim.uv or vim.loop

---FIXIT: try to delete convenience methods down below to not keep unused code

---@class agentic.acp.ACPClient
---@field protocol_version number
---@field capabilities agentic.acp.ClientCapabilities
---@field agent_capabilities? agentic.acp.AgentCapabilities
---@field config agentic.acp.ClientConfig
---@field callbacks table<number, fun(result?: table, err?: agentic.acp.ACPError)>
---@field transport? agentic.acp.ACPTransportInstance
local ACPClient = {}

-- ACP Error codes
ACPClient.ERROR_CODES = {
    TRANSPORT_ERROR = -32000,
    PROTOCOL_ERROR = -32001,
    TIMEOUT_ERROR = -32002,
    AUTH_REQUIRED = -32003,
    SESSION_NOT_FOUND = -32004,
    PERMISSION_DENIED = -32005,
    INVALID_REQUEST = -32006,
}

---@param config? agentic.acp.ClientConfig
---@return agentic.acp.ACPClient
function ACPClient:new(config)
    ---@type agentic.acp.ACPClient
    local instance = {
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
        pending_responses = {},
        callbacks = {},
        transport = nil,
        config = config or {},
        state = "disconnected",
        reconnect_count = 0,
        heartbeat_timer = nil,
    }

    local client = setmetatable(instance, { __index = self }) --[[@as agentic.acp.ACPClient]]

    client:_setup_transport()
    client:connect()
    return client
end

function ACPClient:_setup_transport()
    local transport_type = self.config.transport_type or "stdio"

    if transport_type == "stdio" then
        self.transport = self:_create_stdio_transport()
    else
        error("Unsupported transport type: " .. transport_type)
    end
end

---Set connection state
---@param state agentic.acp.ClientConnectionState
function ACPClient:_set_state(state)
    local old_state = self.state
    self.state = state

    if self.config.on_state_change then
        self.config.on_state_change(state, old_state)
    end
end

---Create error object
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

function ACPClient:_create_stdio_transport()
    --- @class agentic.acp.ACPTransportInstance
    local transport = {
        --- @type uv.uv_pipe_t|nil
        stdin = nil,
        --- @type uv.uv_pipe_t|nil
        stdout = nil,
        --- @type uv.uv_process_t|nil
        process = nil,
    }

    --- @param transport_self agentic.acp.ACPTransportInstance
    --- @param data string
    function transport.send(transport_self, data)
        if transport_self.stdin and not transport_self.stdin:is_closing() then
            transport_self.stdin:write(data .. "\n")
            return true
        end
        return false
    end

    --- @param transport_self agentic.acp.ACPTransportInstance
    --- @param on_message fun(message: any)
    function transport.start(transport_self, on_message)
        self:_set_state("connecting")

        local stdin = uv.new_pipe(false)
        local stdout = uv.new_pipe(false)
        local stderr = uv.new_pipe(false)

        if not stdin or not stdout or not stderr then
            self:_set_state("error")
            error("Failed to create pipes for ACP agent")
        end

        local args = vim.deepcopy(self.config.args or {})
        local env = self.config.env

        local final_env = {}

        local path = vim.fn.getenv("PATH")
        if path then
            final_env[#final_env + 1] = "PATH=" .. path
        end

        if env then
            for k, v in pairs(env) do
                final_env[#final_env + 1] = k .. "=" .. v
            end
        end

        -- local handle, pid = uv.spawn(self.config.command, {
        ---@diagnostic disable-next-line: missing-fields
        local handle, pid = uv.spawn("claude-code-acp", {
            args = args,
            env = final_env,
            stdio = { stdin, stdout, stderr },
            detached = false,
        }, function(code, signal)
            logger.debug(
                "ACP agent exited with code ",
                code,
                " and signal ",
                signal
            )
            self:_set_state("disconnected")

            if transport_self.process then
                transport_self.process:close()
                transport_self.process = nil
            end

            if
                self.config.reconnect
                and self.reconnect_count
                    < (self.config.max_reconnect_attempts or 3)
            then
                self.reconnect_count = self.reconnect_count + 1
                vim.defer_fn(function()
                    if self.state == "disconnected" then
                        self:connect()
                    end
                end, 2000)
            end
        end)

        logger.debug("Spawned ACP agent process with PID ", tostring(pid))

        if not handle then
            self:_set_state("error")
            error("Failed to spawn ACP agent process")
        end

        transport_self.process = handle
        transport_self.stdin = stdin
        transport_self.stdout = stdout

        self:_set_state("connected")

        local chunks = ""
        stdout:read_start(function(err, data)
            if err then
                vim.notify("ACP stdout error: " .. err, vim.log.levels.ERROR)
                self:_set_state("error")
                return
            end

            if data then
                chunks = chunks .. data

                -- Split on newlines and process complete JSON-RPC messages
                local lines = vim.split(chunks, "\n", { plain = true })
                chunks = lines[#lines]

                for i = 1, #lines - 1 do
                    local line = vim.trim(lines[i])
                    if line ~= "" then
                        local ok, message = pcall(vim.json.decode, line)
                        if ok then
                            on_message(message)
                        else
                            vim.schedule(function()
                                vim.notify(
                                    "Failed to parse JSON-RPC message: " .. line,
                                    vim.log.levels.WARN
                                )
                            end)
                        end
                    end
                end
            end
        end)

        stderr:read_start(function(_, data)
            if data then
                if
                    not (
                        data:match("Session not found")
                        or data:match("session/prompt")
                    )
                then
                    vim.schedule(function()
                        logger.debug("ACP stderr: ", data)
                    end)
                end
            end
        end)
    end

    --- @param transport_self agentic.acp.ACPTransportInstance
    function transport.stop(transport_self)
        if
            transport_self.process and not transport_self.process:is_closing()
        then
            local process = transport_self.process
            transport_self.process = nil

            if not process then
                return
            end

            -- Try to terminate gracefully
            pcall(function()
                process:kill(15)
            end)
            -- then force kill, it'll fail harmlessly if already exited
            pcall(function()
                process:kill(9)
            end)

            process:close()
        end

        if transport_self.stdin then
            transport_self.stdin:close()
            transport_self.stdin = nil
        end
        if transport_self.stdout then
            transport_self.stdout:close()
            transport_self.stdout = nil
        end

        self:_set_state("disconnected")
    end

    return transport
end

---@return number
function ACPClient:_next_id()
    self.id_counter = self.id_counter + 1
    return self.id_counter
end

---Send JSON-RPC request
---@param method string
---@param params? table
---@param callback? fun(result: table|nil, err: agentic.acp.ACPError|nil)
---@return table|nil result
---@return agentic.acp.ACPError|nil err
function ACPClient:_send_request(method, params, callback)
    local id = self:_next_id()
    local message = {
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params or {},
    }

    if callback then
        self.callbacks[id] = callback
    end

    local data = vim.inspect(message)
    logger.debug_to_file("request: " .. data .. string.rep("=", 100) .. "\n\n")

    if not self.transport:send(data) then
        return nil
    end

    if not callback then
        return self:_wait_response(id)
    end
end

function ACPClient:_wait_response(id)
    local start_time = vim.loop.now()
    local timeout = self.config.timeout or 100000

    while vim.loop.now() - start_time < timeout do
        vim.wait(10)

        if self.pending_responses[id] then
            local result, err = unpack(self.pending_responses[id])
            self.pending_responses[id] = nil
            return result, err
        end
    end

    return nil,
        self:_create_error(
            self.ERROR_CODES.TIMEOUT_ERROR,
            "Timeout waiting for response"
        )
end

---Send JSON-RPC notification
---@param method string
---@param params table?
function ACPClient:_send_notification(method, params)
    local message = {
        jsonrpc = "2.0",
        method = method,
        params = params or {},
    }

    local data = vim.inspect(message)
    logger.debug_to_file(
        "notification: " .. data .. string.rep("=", 100) .. "\n\n"
    )

    self.transport:send(data)
end

---Send JSON-RPC result
---@param id number
---@param result table | string | vim.NIL | nil
---@return nil
function ACPClient:_send_result(id, result)
    local message = { jsonrpc = "2.0", id = id, result = result }

    local data = vim.json.encode(message)
    logger.debug_to_file(
        "request: " .. data .. "\n" .. string.rep("=", 100) .. "\n"
    )

    self.transport:send(data)
end

---Send JSON-RPC error
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

---Handle received message
---@param message table
function ACPClient:_handle_message(message)
    -- Check if this is a notification (has method but no id, or has both method and id for notifications)
    if message.method and not message.result and not message.error then
        -- This is a notification
        self:_handle_notification(message.id, message.method, message.params)
    elseif message.id and (message.result or message.error) then
        logger.debug_to_file(
            "response: ",
            vim.inspect(message),
            "\n",
            string.rep("=", 100),
            "\n\n"
        )

        local callback = self.callbacks[message.id]
        if callback then
            callback(message.result, message.error)
            self.callbacks[message.id] = nil
        else
            self.pending_responses[message.id] =
                { message.result, message.error }
        end
    else
        -- Unknown message type
        vim.notify(
            "Unknown message type: " .. vim.inspect(message),
            vim.log.levels.WARN
        )
    end
end

---Handle notification
---@param method string
---@param params table
function ACPClient:_handle_notification(message_id, method, params)
    logger.debug_to_file("method: ", method, "\n\n")
    logger.debug_to_file(
        vim.inspect(params),
        "\n",
        string.rep("=", 100),
        "\n\n"
    )

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

    if self.config.handlers and self.config.handlers.on_session_update then
        vim.schedule(function()
            self.config.handlers.on_session_update(update)
        end)
    end
end

---@param message_id number
---@param request agentic.acp.RequestPermission
function ACPClient:_handle_request_permission(message_id, request)
    if not request.sessionId or not request.toolCall then
        error("Invalid request_permission")
        return
    end

    if self.config.handlers and self.config.handlers.on_request_permission then
        vim.schedule(function()
            self.config.handlers.on_request_permission(
                request,
                function(option_id)
                    self:_send_result(
                        message_id,
                        { --- @type agentic.acp.RequestPermissionOutcome
                            outcome = {
                                outcome = "selected",
                                optionId = option_id,
                            },
                        }
                    )
                end
            )
        end)
    end
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

    if self.config.handlers and self.config.handlers.on_read_file then
        vim.schedule(function()
            self.config.handlers.on_read_file(
                path,
                params.line ~= vim.NIL and params.line or nil,
                params.limit ~= vim.NIL and params.limit or nil,
                function(content)
                    self:_send_result(message_id, { content = content })
                end
            )
        end)
    end
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

    if self.config.handlers and self.config.handlers.on_write_file then
        vim.schedule(function()
            self.config.handlers.on_write_file(path, content, function(error)
                self:_send_result(message_id, error == nil and vim.NIL or error)
            end)
        end)
    end
end

function ACPClient:connect()
    if self.state ~= "disconnected" then
        return
    end

    self.transport:start(function(message)
        self:_handle_message(message)
    end)

    self:initialize()
end

function ACPClient:stop()
    self.transport:stop()

    self.pending_responses = {}
    self.reconnect_count = 0
end

function ACPClient:initialize()
    if self.state ~= "connected" then
        local error = self:_create_error(
            self.ERROR_CODES.PROTOCOL_ERROR,
            "Cannot initialize: client not connected"
        )
        return error
    end

    self:_set_state("initializing")

    local result = self:_send_request("initialize", {
        protocolVersion = self.protocol_version,
        clientCapabilities = self.capabilities,
    })

    if not result then
        self:_set_state("error")
        vim.notify("Failed to initialize", vim.log.levels.ERROR)
        return
    end

    self.protocol_version = result.protocolVersion
    self.agent_capabilities = result.agentCapabilities
    self.auth_methods = result.authMethods or {}

    -- Check if we need to authenticate
    local auth_method = self.config.auth_method

    if auth_method then
        logger.debug("Authenticating with method ", auth_method)
        self:authenticate(auth_method)
        self:_set_state("ready")
    else
        logger.debug("No authentication method found or specified")
        self:_set_state("ready")
    end
end

---@param method_id string
function ACPClient:authenticate(method_id)
    return self:_send_request("authenticate", {
        methodId = method_id,
    })
end

---@param cwd string
---@param mcp_servers table[]?
---@return string|nil session_id
---@return agentic.acp.ACPError|nil err
function ACPClient:create_session(cwd, mcp_servers)
    local result, err = self:_send_request("session/new", {
        cwd = cwd,
        mcpServers = mcp_servers or {},
    })

    if err then
        vim.notify(
            "Failed to create session: " .. err.message,
            vim.log.levels.ERROR
        )
        return nil, err
    end

    if not result then
        err = self:_create_error(
            self.ERROR_CODES.PROTOCOL_ERROR,
            "Failed to create session: missing result"
        )
        return nil, err
    end

    return result.sessionId, nil
end

---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@return table|nil result
function ACPClient:load_session(session_id, cwd, mcp_servers)
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

    return self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
    })
end

---@param session_id string
---@param prompt table[]
---@param callback? fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
    local params = {
        sessionId = session_id,
        prompt = prompt,
    }

    return self:_send_request("session/prompt", params, callback)
end

---@param session_id string
function ACPClient:cancel_session(session_id)
    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

---@return boolean
function ACPClient:is_ready()
    return self.state == "ready"
end

---@return boolean
function ACPClient:is_connected()
    return self.state ~= "disconnected" and self.state ~= "error"
end

---@param callback function
---@param timeout number? Timeout in milliseconds
function ACPClient:wait_ready(callback, timeout)
    if self:is_ready() then
        callback(nil)
        return
    end

    local timeout_ms = timeout or 10000
    local start_time = uv.now()

    local function check_ready()
        if self:is_ready() then
            callback(nil)
        elseif self.state == "error" then
            callback(
                self:_create_error(
                    self.ERROR_CODES.PROTOCOL_ERROR,
                    "Client entered error state while waiting"
                )
            )
        elseif uv.now() - start_time > timeout_ms then
            callback(
                self:_create_error(
                    self.ERROR_CODES.TIMEOUT_ERROR,
                    "Timeout waiting for client to be ready"
                )
            )
        else
            vim.defer_fn(check_ready, 100)
        end
    end

    check_ready()
end

return ACPClient

---@class agentic.acp.ClientCapabilities
---@field fs agentic.acp.FileSystemCapability
---@field terminal boolean
---@field clientInfo { name: string, version: string }

--FIXIT: test what happens if we inform we cant read file or cant write
-- note: it might require to comment the methods below
--
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

---@class agentic.acp.BaseContent
---@field type "text" | "image" | "audio" | "resource_link" | "resource"
---@field annotations? agentic.acp.Annotations

---@class agentic.acp.TextContent : agentic.acp.BaseContent
---@field type "text"
---@field text string

---@class agentic.acp.ImageContent : agentic.acp.BaseContent
---@field type "image"
---@field data string
---@field mimeType string
---@field uri? string

---@class agentic.acp.AudioContent : agentic.acp.BaseContent
---@field type "audio"
---@field data string
---@field mimeType string

---@class agentic.acp.ResourceLinkContent : agentic.acp.BaseContent
---@field type "resource_link"
---@field uri string
---@field name string
---@field description? string
---@field mimeType? string
---@field size? number
---@field title? string

---@class agentic.acp.ResourceContent : agentic.acp.BaseContent
---@field type "resource"
---@field resource agentic.acp.EmbeddedResource

---@class agentic.acp.EmbeddedResource
---@field uri string
---@field text? string
---@field blob? string
---@field mimeType? string

---@class agentic.acp.Annotations
---@field audience? any[]
---@field lastModified? string
---@field priority? number

---@alias agentic.acp.Content agentic.acp.TextContent | agentic.acp.ImageContent | agentic.acp.AudioContent | agentic.acp.ResourceLinkContent | agentic.acp.ResourceContent

---@class agentic.acp.RawInput
---@field file_path string
---@field new_string? string
---@field old_string? string
---@field replace_all? boolean
---@field description? string
---@field command? string
---@field url? string Usually from the fetch tool
---@field query? string Usually from the web_search tool
---@field timeout? number

---@class agentic.acp.ToolCall
---@field toolCallId string
---@field rawInput? agentic.acp.RawInput
---
---@class agentic.acp.BaseToolCallContent
---@field type "content" | "diff"

---@class agentic.acp.ToolCallRegularContent : agentic.acp.BaseToolCallContent
---@field type "content"
---@field content agentic.acp.Content

---@class agentic.acp.ToolCallDiffContent : agentic.acp.BaseToolCallContent
---@field type "diff"
---@field path string
---@field oldText string
---@field newText string

---@alias ACPToolCallContent agentic.acp.ToolCallRegularContent | agentic.acp.ToolCallDiffContent

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

---@class agentic.acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan" | "available_commands_update"

---@class agentic.acp.UserMessageChunk : agentic.acp.BaseSessionUpdate
---@field sessionUpdate "user_message_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.AgentMessageChunk : agentic.acp.BaseSessionUpdate
---@field sessionUpdate "agent_message_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.AgentThoughtChunk : agentic.acp.BaseSessionUpdate
---@field sessionUpdate "agent_thought_chunk"
---@field content agentic.acp.Content

---@class agentic.acp.ToolCallUpdate
---@field sessionUpdate? "tool_call" | "tool_call_update"
---@field toolCallId string
---@field title? string
---@field kind? agentic.acp.ToolKind
---@field status? agentic.acp.ToolCallStatus
---@field content? ACPToolCallContent[]
---@field locations? agentic.acp.ToolCallLocation[]
---@field rawInput? agentic.acp.RawInput
---@field rawOutput? table

---@class agentic.acp.PlanUpdate : agentic.acp.BaseSessionUpdate
---@field sessionUpdate "plan"
---@field entries agentic.acp.PlanEntry[]

---@class agentic.acp.AvailableCommandsUpdate : agentic.acp.BaseSessionUpdate
---@field sessionUpdate "available_commands_update"
---@field availableCommands agentic.acp.AvailableCommand[]

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

---@alias agentic.acp.TransportType "stdio" | "tcp" | "websocket"

---@class agentic.acp.ACPTransport
---@field send function
---@field start function
---@field stop function

---@alias agentic.acp.ClientConnectionState "disconnected" | "connecting" | "connected" | "initializing" | "ready" | "error"

---@class agentic.acp.ACPError
---@field code number
---@field message string
---@field data? any

---@class agentic.acp.ClientHandlers
---@field on_session_update? fun(update: agentic.acp.UserMessageChunk | agentic.acp.AgentMessageChunk | agentic.acp.AgentThoughtChunk | agentic.acp.ToolCallUpdate | agentic.acp.PlanUpdate | agentic.acp.AvailableCommandsUpdate)
---@field on_request_permission? fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
---@field on_read_file? fun(path: string, line: integer | nil, limit: integer | nil, callback: fun(content: string)): nil
---@field on_write_file? fun(path: string, content: string, callback: fun(error: string|nil)): nil
---@field on_error? fun(error: table)

---@class agentic.acp.ClientConfig
---@field transport_type? agentic.acp.TransportType
---@field command? string Command to spawn agent (for stdio)
---@field args? string[] Arguments for agent command
---@field env? table<string, string> Environment variables
---@field host? string Host for tcp/websocket
---@field port? number Port for tcp/websocket
---@field timeout? number Request timeout in milliseconds
---@field reconnect? boolean Enable auto-reconnect
---@field max_reconnect_attempts? number Maximum reconnection attempts
---@field heartbeat_interval? number Heartbeat interval in milliseconds
---@field auth_method? string Authentication method
---@field handlers? agentic.acp.ClientHandlers
---@field on_state_change? fun(new_state: agentic.acp.ClientConnectionState, old_state: agentic.acp.ClientConnectionState)
