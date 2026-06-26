local Logger = require("agentic.utils.logger")
local JsonFormat = require("agentic.utils.json_format")
local transport_module = require("agentic.acp.acp_transport")
local uv = vim.uv or vim.loop

--- Default time with no inbound activity before an in-flight request is
--- treated as stalled. A suspended/hung agent child keeps its stdio pipes
--- open and never exits, so the process-exit path never fires; this watchdog
--- is the only thing that surfaces such a dead connection.
local DEFAULT_REQUEST_TIMEOUT_MS = 60000

--- How often the watchdog checks for inactivity while a request is pending.
--- Coarse on purpose: the cost is one subtraction per tick, and the timer is
--- only armed while at least one request is in flight.
local WATCHDOG_CHECK_INTERVAL_MS = 5000

--- Methods the silence watchdog must NOT govern. `session/prompt` can run for
--- minutes while a tool executes, producing no traffic, so silence is not a
--- death signal there; it is guarded separately by the liveness probe. All
--- other (control) RPCs are expected to answer within seconds.
local UNWATCHED_METHODS = {
    ["session/prompt"] = true,
}

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
--- @field ready_listeners fun(client: agentic.acp.ACPClient)[]
--- @field subscribers table<string, agentic.acp.ClientHandlers>
--- @field _last_activity number `uv.now()` of the last inbound message; the watchdog measures silence against it.
--- @field _watchdog_timer? uv.uv_timer_t Repeating inactivity timer, armed only while a watched request is pending.
--- @field _watched_pending table<number, true> Ids of in-flight control requests the silence watchdog governs (excludes session/prompt).

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
        _last_activity = 0,
        _watchdog_timer = nil,
        _watched_pending = {},
    }

    local client = setmetatable(instance, self) --[[@as agentic.acp.ACPClient]]
    client._on_ready = function(c)
        on_ready(c)
        for _, listener in ipairs(c.ready_listeners) do
            vim.schedule(function()
                listener(c)
            end)
        end
        c.ready_listeners = {}
    end

    client:_setup_transport()
    client:_connect()
    return client
end

--- @param callback fun(client: agentic.acp.ACPClient)
function ACPClient:when_ready(callback)
    if self.state == "ready" then
        vim.schedule(function()
            callback(self)
        end)
    else
        self.ready_listeners[#self.ready_listeners + 1] = callback
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
    end
end

--- @protected
--- @param reason string
--- @param code? number Error code to reject with; defaults to TRANSPORT_ERROR.
function ACPClient:_drain_pending_callbacks(reason, code)
    local pending = self.callbacks
    self.callbacks = {}
    self._watched_pending = {}
    self:_disarm_watchdog()

    local err =
        self:__create_error(code or self.ERROR_CODES.TRANSPORT_ERROR, reason)

    for _, callback in pairs(pending) do
        vim.schedule(function()
            pcall(callback, nil, err)
        end)
    end
end

--- Start the inactivity watchdog if it is not already running. Idempotent;
--- safe to call on every request. The timer disarms itself once no requests
--- are pending, so there is no idle cost.
--- @protected
function ACPClient:_arm_watchdog()
    if self._watchdog_timer then
        return
    end

    local timer = uv.new_timer()
    if not timer then
        return
    end

    self._watchdog_timer = timer
    timer:start(
        WATCHDOG_CHECK_INTERVAL_MS,
        WATCHDOG_CHECK_INTERVAL_MS,
        function()
            self:_check_watchdog()
        end
    )
end

--- Stop and release the watchdog timer.
--- @protected
function ACPClient:_disarm_watchdog()
    local timer = self._watchdog_timer
    if not timer then
        return
    end

    self._watchdog_timer = nil
    timer:stop()
    if not timer:is_closing() then
        timer:close()
    end
end

--- Watchdog tick: runs in libuv fast context, so it only reads `uv.now()`
--- and touches plain Lua state, deferring the actual handling to the main loop.
--- @protected
function ACPClient:_check_watchdog()
    if not next(self._watched_pending) then
        self:_disarm_watchdog()
        return
    end

    local timeout = self.provider_config.timeout or DEFAULT_REQUEST_TIMEOUT_MS

    if uv.now() - self._last_activity >= timeout then
        -- Disarm here (still cheap, fast-context-safe) so a slow main loop
        -- can't queue several stall handlers before the first one runs.
        self:_disarm_watchdog()
        vim.schedule(function()
            self:_on_request_stall(timeout)
        end)
    end
end

--- Surface a stalled connection: reject the in-flight control requests with a
--- timeout error so their UI resets instead of hanging. Any in-flight
--- session/prompt is deliberately left untouched; a long silent tool run is
--- not a death signal and is guarded by the liveness probe.
--- @protected
--- @param timeout number
function ACPClient:_on_request_stall(timeout)
    if not next(self._watched_pending) then
        return
    end

    -- Re-check: a response may have arrived in the gap between the watchdog
    -- disarming and this handler running via vim.schedule.
    if uv.now() - self._last_activity < timeout then
        return
    end

    Logger.notify(
        string.format(
            "Agent control request timed out after %ds.",
            math.floor(timeout / 1000)
        ),
        vim.log.levels.WARN
    )

    self:_reject_watched("Request timed out", self.ERROR_CODES.TIMEOUT_ERROR)
end

--- Reject only the watched (control) requests, leaving session/prompt and any
--- other unwatched callback in place.
--- @protected
--- @param reason string
--- @param code? number
function ACPClient:_reject_watched(reason, code)
    local watched = self._watched_pending
    self._watched_pending = {}
    self:_disarm_watchdog()

    local err =
        self:__create_error(code or self.ERROR_CODES.TRANSPORT_ERROR, reason)

    for id in pairs(watched) do
        local callback = self.callbacks[id]
        self.callbacks[id] = nil
        if callback then
            vim.schedule(function()
                pcall(callback, nil, err)
            end)
        end
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

    -- Arm the silence watchdog for control requests only. session/prompt is
    -- excluded: it can run silently for minutes and is guarded separately.
    if not UNWATCHED_METHODS[method] then
        self._watched_pending[id] = true
        self._last_activity = uv.now()
        self:_arm_watchdog()
    end

    if self.transport:send(data) == false then
        -- The pipe is already closing; reject now rather than wait, since no
        -- response can ever arrive. Only an explicit false counts as failure;
        -- an ambiguous return falls back to the watchdog. Applies to every
        -- method, including session/prompt, since the send genuinely failed.
        self.callbacks[id] = nil
        self._watched_pending[id] = nil
        if not next(self._watched_pending) then
            self:_disarm_watchdog()
        end

        local err = self:__create_error(
            self.ERROR_CODES.TRANSPORT_ERROR,
            "Failed to send request: transport not writable"
        )
        vim.schedule(function()
            pcall(callback, nil, err)
        end)
    end
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

--- @param message agentic.acp.ResponseRaw
function ACPClient:_handle_message(message)
    -- Any inbound message (response or streamed update) counts as activity and
    -- keeps the watchdog from tripping during a legitimately long generation.
    self._last_activity = uv.now()

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
            self._watched_pending[message.id] = nil
            if not next(self._watched_pending) then
                self:_disarm_watchdog()
            end
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
        -- `params` is declared as a bare `table`, which cannot satisfy the
        -- structured `RequestPermission` shape. The callee guards the payload.
        --- @diagnostic disable-next-line: param-type-mismatch
        self:__handle_request_permission(message_id, params)
    elseif method == "fs/read_text_file" or method == "fs/write_text_file" then
        Logger.debug(
            string.format("Received '%s' notification, ignoring it", method)
        )
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

--- Force a fresh agent process in place: kill the current (possibly hung)
--- child, then respawn and re-initialize. `stop()` drains every pending
--- callback and moves the state to "disconnected", which `_connect()` requires.
--- Sessions are not restored here; the caller re-establishes them once the
--- client reaches "ready" again (via `when_ready`).
function ACPClient:reconnect()
    self.transport:stop()
    self.reconnect_count = 0
    self:_connect()
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
--- @param on_load_complete fun(err: agentic.acp.ACPError|nil)|nil
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
    }, function(_result, err)
        if err and self.subscribers[session_id] == handlers then
            self.subscribers[session_id] = nil
        end

        if on_load_complete then
            on_load_complete(err)
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
