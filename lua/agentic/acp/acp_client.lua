local Logger = require("agentic.utils.logger")
local JsonFormat = require("agentic.utils.json_format")
local transport_module = require("agentic.acp.acp_transport")

--- JSON-RPC "Method not found", the answer the ACP spec requires for a request
--- naming a method the receiver does not implement.
local JSONRPC_METHOD_NOT_FOUND = -32601

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
    write = true,
    switch_mode = true,
}

--- Split from the class so LuaLS validates instance fields without the prototype methods.
--- @class agentic.acp.ACPClientData
--- @field provider_config agentic.acp.ACPProviderConfig
--- @field id_counter number
--- @field state agentic.acp.ClientConnectionState
--- @field protocol_version number
--- @field client_info agentic.acp.ClientInfo
--- @field capabilities agentic.acp.ClientCapabilities
--- @field agent_capabilities? agentic.acp.AgentCapabilities
--- @field agent_info? agentic.acp.AgentInfo
--- @field auth_methods agentic.acp.AuthMethod[]
--- @field callbacks table<number, fun(result: table|nil, err: agentic.acp.ACPError|nil)>
--- @field transport? agentic.acp.ACPTransportInstance
--- @field ready_listeners { on_ready: fun(client: agentic.acp.ACPClient), on_failure: fun(err: agentic.acp.ACPError)|nil }[]
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
--- @return agentic.acp.ACPClient client
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
                readTextFile = false,
                writeTextFile = false,
            },
            terminal = false,
            session = {
                configOptions = {
                    boolean = vim.empty_dict(),
                },
            },
        },
        auth_methods = {},
        ready_listeners = {},
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

--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @param on_failure fun(err: agentic.acp.ACPError)|nil
--- @param err agentic.acp.ACPError|nil
function ACPClient:_schedule_ready_listener(on_ready, on_failure, err)
    vim.schedule(function()
        if err then
            if on_failure then
                on_failure(err)
            end
            return
        end

        if self.state == "ready" then
            on_ready(self)
        elseif on_failure then
            on_failure(
                self:__create_error(
                    self.ERROR_CODES.TRANSPORT_ERROR,
                    self.state
                )
            )
        end
    end)
end

--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @param on_failure fun(err: agentic.acp.ACPError)|nil
function ACPClient:when_ready(on_ready, on_failure)
    if self.state == "ready" then
        self:_schedule_ready_listener(on_ready, on_failure, nil)
    elseif self.state == "error" or self.state == "disconnected" then
        local err =
            self:__create_error(self.ERROR_CODES.TRANSPORT_ERROR, self.state)
        if on_failure then
            self:_schedule_ready_listener(on_ready, on_failure, err)
        end
    else
        self.ready_listeners[#self.ready_listeners + 1] = {
            on_ready = on_ready,
            on_failure = on_failure,
        }
    end
end

--- @param session_id string
--- @param handlers agentic.acp.ClientHandlers
function ACPClient:_subscribe(session_id, handlers)
    -- One subscriber per session ID: a replacement reroutes every update and permission
    -- prompt to the newer handlers. Legitimate on a reconnect replay, a defect when two
    -- managers claim one ID. Logged, not blocked: refusing the write would strand a
    -- reconnect's fresh handlers.
    if
        self.subscribers[session_id]
        and self.subscribers[session_id] ~= handlers
    then
        Logger.debug(
            "Replacing existing subscriber for session_id: " .. session_id
        )
    end

    self.subscribers[session_id] = handlers
end

--- @protected
--- @param session_id string
--- @param callback fun(sub: agentic.acp.ClientHandlers): nil
--- @param on_missing fun()|nil Runs when no subscriber answers; a JSON-RPC request needs it
function ACPClient:__with_subscriber(session_id, callback, on_missing)
    if not self.subscribers[session_id] then
        Logger.debug("No subscriber found for session_id: " .. session_id)

        if on_missing then
            on_missing()
        end

        return
    end

    vim.schedule(function()
        -- Re-resolved here: `cancel_session` can drop the subscriber while this
        -- callback sits in the queue.
        local subscriber = self.subscribers[session_id]

        if subscriber then
            callback(subscriber)
        elseif on_missing then
            on_missing()
        end
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

    if state == "disconnected" or state == "error" then
        self:_drain_pending_callbacks(state)
        self:_drain_ready_listeners(state)
    elseif state == "ready" then
        self:_drain_ready_listeners(nil)
    end
end

--- @param failure_reason string|nil
function ACPClient:_drain_ready_listeners(failure_reason)
    local listeners = self.ready_listeners
    self.ready_listeners = {}

    local err = failure_reason
            and self:__create_error(
                self.ERROR_CODES.TRANSPORT_ERROR,
                failure_reason
            )
        or nil

    for _, listener in ipairs(listeners) do
        if err and listener.on_failure then
            self:_schedule_ready_listener(
                listener.on_ready,
                listener.on_failure,
                err
            )
        elseif not err then
            self:_schedule_ready_listener(
                listener.on_ready,
                listener.on_failure,
                nil
            )
        end
    end
end

--- @protected
--- @param reason string
function ACPClient:_drain_pending_callbacks(reason)
    local pending = self.callbacks
    self.callbacks = {}

    local err = self:__create_error(self.ERROR_CODES.TRANSPORT_ERROR, reason)

    for _, callback in pairs(pending) do
        vim.schedule(function()
            pcall(callback, nil, err)
        end)
    end
end

--- @protected
--- @param code number
--- @param message string
--- @param data any|nil
--- @return agentic.acp.ACPError error
function ACPClient:__create_error(code, message, data)
    return {
        code = code,
        message = message,
        data = data,
    }
end

--- @return number id
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
function ACPClient:__send_result(id, result)
    local message = { jsonrpc = "2.0", id = id, result = result }

    local data = vim.json.encode(message)
    Logger.debug_to_file("request:", message)

    self.transport:send(data)
end

--- @protected
--- @param id number
--- @param code number
--- @param message string
function ACPClient:__send_error(id, code, message)
    local frame = {
        jsonrpc = "2.0",
        id = id,
        error = { code = code, message = message },
    }

    local data = vim.json.encode(frame)
    Logger.debug_to_file("error response:", frame)

    self.transport:send(data)
end

--- @param message agentic.acp.ResponseRaw
function ACPClient:_handle_message(message)
    -- Chunks are not logged: they would flood the log file.
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

    if message.method and not message.result and not message.error then
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

--- Dispatches both notifications and requests: `_handle_message` routes on
--- `method`, so `message_id` is `nil` for a notification and set for a request.
--- @param message_id number|nil
--- @param method string
--- @param params table
function ACPClient:_handle_notification(message_id, method, params)
    if method == "session/update" then
        self:__handle_session_update(params)
    elseif method == "session/request_permission" then
        -- `params` is declared as a bare `table`, which cannot satisfy the
        -- structured `RequestPermission` shape. The callee guards the payload.
        --- @diagnostic disable-next-line: param-type-mismatch
        self:__handle_request_permission(message_id, params)
    elseif method == "fs/read_text_file" or method == "fs/write_text_file" then
        Logger.debug(
            string.format("Received '%s' notification, ignoring it", method)
        )
    else
        self:__handle_unknown_method(message_id, method)
    end
end

--- ACP reserves `_`-prefixed method names for vendor extensions, and the two
--- message shapes carry opposite obligations: an unrecognized notification
--- SHOULD be ignored, while a request MUST be answered -- with `-32601` when
--- the method is not implemented.
--- https://agentclientprotocol.com/protocol/extensibility
---
--- Answering matters beyond extensions: the agent blocks until its `id` comes
--- back, and the subprocess is shared across every session (ADR 0004), so one
--- stranded `id` hangs all of them. Only `session/request_permission` of the
--- client-bound requests is implemented here; every other one lands below.
--- @protected
--- @param message_id number|nil `nil` for a notification
--- @param method any Unvalidated: `_handle_message` only checks it is truthy
function ACPClient:__handle_unknown_method(message_id, method)
    local kind = message_id and "request" or "notification"

    if type(method) == "string" and method:sub(1, 1) == "_" then
        Logger.debug(
            string.format("Received custom %s '%s', ignoring it", kind, method)
        )
    else
        -- `method` is concatenated, never indexed: a malformed frame can carry
        -- a non-string, and `on_message` runs unprotected in the transport read
        -- loop where a throw is fatal.
        Logger.notify("Unknown " .. kind .. " method: " .. method)
    end

    if message_id then
        self:__send_error(
            message_id,
            JSONRPC_METHOD_NOT_FOUND,
            "Method not found"
        )
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
        update.kind = update.kind or "other"
        update.status = update.status or "pending"

        if not KNOWN_ACP_KINDS[update.kind] then
            -- notify, not debug: we want users to report these as issues.
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

--- Agents send either `nil` or `vim.NIL` for empty content.
--- @param possible_string string|nil|vim.NIL
--- @return string[] lines
function ACPClient:safe_split(possible_string)
    if type(possible_string) == "string" then
        return vim.split(possible_string, "\n")
    end

    return {}
end

--- @protected
--- @param update agentic.acp.ToolCallBase
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function ACPClient:__build_tool_call_message(update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
    }

    if update.kind then
        message.kind = update.kind
    end

    if update.status then
        message.status = update.status
    end

    if update.title and update.title ~= "" then
        message.argument = update.title
    end

    if type(update.content) == "table" then
        local body_parts = {}
        for _, content in ipairs(update.content) do
            if content then
                if
                    content.type == "content"
                    and content.content
                    and content.content.text
                then
                    table.insert(
                        body_parts,
                        self:safe_split(content.content.text)
                    )
                elseif content.type == "diff" then
                    local new_string = content.newText
                    local old_string = content.oldText

                    message.diff = {
                        new = self:safe_split(new_string),
                        old = self:safe_split(old_string),
                        all = false,
                    }

                    if content.path then
                        message.file_path = content.path
                    end
                end
            end
        end

        if #body_parts > 0 then
            local merged = body_parts[1]
            for i = 2, #body_parts do
                table.insert(merged, "---")
                vim.list_extend(merged, body_parts[i])
            end
            message.body = merged
        end
    end

    -- Fallback for providers that send no `content` (OpenCode).
    local raw_input = type(update.rawInput) == "table" and update.rawInput
        or nil

    if not message.diff and update.kind == "edit" and raw_input then
        local new_string = raw_input.new_string or raw_input.newString
        local old_string = raw_input.old_string or raw_input.oldString

        if new_string then
            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = raw_input.replace_all or false,
            }
        end
    end

    if not message.file_path and raw_input then
        message.file_path = raw_input.file_path or raw_input.filePath
    end

    if not message.file_path and type(update.locations) == "table" then
        local first_location = update.locations[1]
        if first_location and first_location.path then
            message.file_path = first_location.path
        end
    end

    -- `read` is skipped: its renderer treats `#body` as a line count.
    if
        not message.body
        and not message.diff
        and update.kind ~= "read"
        and raw_input
        and not vim.tbl_isempty(raw_input)
    then
        if type(raw_input.command) == "string" and raw_input.command ~= "" then
            message.argument = raw_input.command
            if
                type(raw_input.description) == "string"
                and raw_input.description ~= ""
            then
                message.body = self:safe_split(raw_input.description)
            end
        else
            message.body = vim.split(JsonFormat.format_value(raw_input), "\n")
        end
    end

    return message
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function ACPClient:__handle_tool_call(session_id, update)
    local message = self:__build_tool_call_message(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function ACPClient:__handle_tool_call_update(session_id, update)
    local message = self:__build_tool_call_message(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

--- @protected
--- @param message_id number
--- @param request agentic.acp.RequestPermission|nil
function ACPClient:__handle_request_permission(message_id, request)
    local answered = false

    --- Idempotent: the dispatch guard cancels on a throw that may land after
    --- the subscriber already answered, and two results on one `id` is a
    --- protocol violation.
    --- @param option_id string|nil nil is a cancellation, not a selection
    local function answer(option_id)
        if answered then
            return
        end

        answered = true

        --- @type agentic.acp.RequestPermissionOutcome
        local outcome = option_id
                and { outcome = "selected", optionId = option_id }
            or { outcome = "cancelled" }

        self:__send_result(message_id, {
            outcome = outcome,
        })
    end

    if
        type(request) ~= "table"
        or type(request.sessionId) ~= "string"
        or type(request.toolCall) ~= "table"
    then
        -- Checked by TYPE, not truthiness: a non-string `sessionId` silently
        -- matches no subscriber, and a truthy non-table `toolCall` throws
        -- inside the scheduled `__build_tool_call_message`. Either way the
        -- `id` is owed an answer.
        Logger.notify(
            "Invalid session/request_permission: " .. vim.inspect(request)
        )
        answer(nil)

        return
    end

    local session_id = request.sessionId

    self:__with_subscriber(session_id, function(subscriber)
        -- The type guard above only covers the payload's top level; nested
        -- shapes and both subscriber callbacks can still throw in here.
        -- `vim.schedule` swallows that throw, so the read loop survives while
        -- the shared subprocess waits on the `id` forever. See
        -- `lua/agentic/acp/AGENTS.md`.
        local ok, err = pcall(function()
            local message = self:__build_tool_call_message(request.toolCall)
            subscriber.on_tool_call_update(message)

            subscriber.on_request_permission(request, answer)
        end)

        if not ok then
            -- Always notified: a silent cancel hides a genuine UI bug behind a
            -- permission prompt that merely "didn't appear".
            Logger.notify(
                "Failed to dispatch session/request_permission: "
                    .. tostring(err)
            )
            -- No-op when the subscriber already answered before throwing.
            answer(nil)
        end
    end, function()
        -- The request is still outstanding on the shared provider subprocess.
        answer(nil)
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

        --- @cast result agentic.acp.InitializeResponse
        self.protocol_version = result.protocolVersion
        self.agent_capabilities = result.agentCapabilities
        self.agent_info = result.agentInfo

        local auth_methods = result.authMethods
        if type(auth_methods) ~= "table" or auth_methods == vim.NIL then
            auth_methods = {}
        end
        self.auth_methods = auth_methods

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
--- @param on_load_complete fun(result: agentic.acp.LoadSessionResponse|nil, err: agentic.acp.ACPError|nil)|nil
function ACPClient:load_session(
    session_id,
    cwd,
    mcp_servers,
    handlers,
    on_load_complete
)
    if
        not self.agent_capabilities or not self.agent_capabilities.loadSession
    then
        Logger.notify("Agent does not support loading sessions")
        if on_load_complete then
            on_load_complete(
                nil,
                self:__create_error(
                    -1,
                    "Agent does not support loading sessions"
                )
            )
        end
        return
    end

    self:_subscribe(session_id, handlers)

    self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
    }, function(result, err)
        if not result and not err then
            err = self:__create_error(
                self.ERROR_CODES.PROTOCOL_ERROR,
                "Failed to load session: missing result"
            )
        end

        if err and self.subscribers[session_id] == handlers then
            self.subscribers[session_id] = nil
        end

        if on_load_complete then
            --- @cast result agentic.acp.LoadSessionResponse|nil
            on_load_complete(result, err)
        end
    end)
end

--- @param cwd string
--- @param callback fun(result: agentic.acp.SessionListResponse|nil, err: agentic.acp.ACPError|nil)
function ACPClient:list_sessions(cwd, callback)
    local caps = self.agent_capabilities
    if
        not caps
        or not caps.sessionCapabilities
        or not caps.sessionCapabilities.list
    then
        callback(
            nil,
            self:__create_error(
                self.ERROR_CODES.PROTOCOL_ERROR,
                "Agent does not support listing sessions"
            )
        )
        return
    end

    self:_send_request("session/list", {
        cwd = cwd,
    }, function(result, err)
        if err then
            callback(nil, err)
            return
        end

        if type(result) ~= "table" or not result.sessions then
            callback(
                nil,
                self:__create_error(
                    self.ERROR_CODES.PROTOCOL_ERROR,
                    "Malformed session/list response: missing sessions field"
                )
            )
            return
        end

        --- @cast result agentic.acp.SessionListResponse
        callback(result, nil)
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

    self:_send_request("session/prompt", params, callback)
end

--- @param session_id string
--- @param mode_id string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_mode(session_id, mode_id, callback)
    local params = {
        sessionId = session_id,
        modeId = mode_id,
    }

    self:_send_request("session/set_mode", params, callback)
end

--- @param params agentic.acp.SetConfigOptionParams
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_config_option(params, callback)
    self:_send_request("session/set_config_option", params, callback)
end

--- @param session_id string
--- @param model_id string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_model(session_id, model_id, callback)
    local params = {
        sessionId = session_id,
        modelId = model_id,
    }

    self:_send_request("session/set_model", params, callback)
end

--- Keeps the session active for the next prompt, unlike `cancel_session`.
--- @param session_id string
function ACPClient:stop_generation(session_id)
    if not session_id then
        return
    end

    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- Destroys the session, unlike `stop_generation`.
--- @param session_id string
function ACPClient:cancel_session(session_id)
    if not session_id then
        return
    end

    -- Dropped first, so no further messages reach the old subscriber.
    self.subscribers[session_id] = nil

    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- @return boolean connected
function ACPClient:is_connected()
    return self.state ~= "disconnected" and self.state ~= "error"
end

return ACPClient
