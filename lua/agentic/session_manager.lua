-- Glues together the Chat widget, the agent instance, and the message writer.

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SlashCommands = require("agentic.acp.slash_commands")
local SessionState = require("agentic.acp.session_state")
local EnvironmentInfo = require("agentic.utils.environment_info")
local Hooks = require("agentic.utils.hooks")

--- @class agentic.SessionManager
--- @field session_id? string
--- @field session_key? integer Registry key, assigned by SessionRegistry.create
--- @field provider_name agentic.UserConfig.ProviderName
--- @field _is_first_message boolean
--- @field is_generating boolean
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field session_state agentic.acp.SessionState
--- @field diff_coordinator agentic.ui.DiffCoordinator
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field history_to_send agentic.ui.ChatHistory.Message[]|nil
--- @field _starter agentic.SessionStarter
--- @field _connection_error boolean
--- @field _destroyed boolean Async callbacks must re-check this at RUN time, not capture it
--- @field _session_creation_failed boolean
--- @field _start_called boolean
--- @field _session_ready_callbacks fun(succeeded: boolean)[]
--- @field _pending_replacement_sources? table<any, boolean>
local SessionManager = {}
SessionManager.__index = SessionManager

--- Codepoints, not display cells
local TITLE_MAX_CHARS = 60

--- @param session agentic.SessionManager
--- @return boolean replaying
local function is_replaying(session)
    --- @diagnostic disable-next-line: invisible
    return session._starter ~= nil and session._starter:is_replaying()
end

--- @param prompt string
--- @return string title
local function title_from_prompt(prompt)
    local title = vim.trim((prompt:gsub("%s+", " ")))

    if vim.fn.strchars(title) > TITLE_MAX_CHARS then
        -- Character-wise, never `sub`: a byte cut lands mid-UTF-8 sequence.
        title = vim.fn.strcharpart(title, 0, TITLE_MAX_CHARS - 1) .. "…"
    end

    return title
end

--- @param agent agentic.acp.ACPClient
--- @param provider_name agentic.UserConfig.ProviderName
function SessionManager:new(agent, provider_name)
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")
    local DiffCoordinator = require("agentic.ui.diff_coordinator")
    local SessionStarter = require("agentic.session_starter")

    self = setmetatable({
        session_id = nil,
        provider_name = provider_name,
        _is_first_message = true,
        is_generating = false,
        _connection_error = false,
        _destroyed = false,
        _session_creation_failed = false,
        _start_called = false,
        history_to_send = nil,
        _session_ready_callbacks = {},
    }, self)

    self.agent = agent
    self._starter = SessionStarter:new(agent)

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(function(input_text)
        return self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.message_writer:set_provider_name(self.agent.provider_config.name)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)

    self.permission_manager = PermissionManager:new(self.message_writer)

    -- Strong reference required: `instances_by_buffer` holds only weak values.
    self.file_picker = FilePicker:new(self.widget.buf_nrs.input)
    SlashCommands.setup_completion(self.widget.buf_nrs.input)

    self.diff_coordinator =
        DiffCoordinator:new(self.widget, self.message_writer)

    self.config_options = AgentConfigOptions:new(self.widget.buf_nrs, {
        on_set_mode_success = function(mode_id)
            self:_set_mode_to_chat_header(mode_id)
            self.widget:schedule_header_refresh()
        end,
        on_config_options_applied = function()
            local mode_id = self.config_options:get_mode_id()
            if mode_id then
                self:_set_mode_to_chat_header(mode_id)
            end
            self.widget:schedule_header_refresh()
        end,
        get_agent_instance = function()
            return self.agent
        end,
        get_session_id = function()
            return self.session_id
        end,
    })

    self.session_state =
        SessionState:new(self.config_options, self.agent.provider_config.name)
    self.widget.session_state = self.session_state

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:rerender()
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_optional_window("code")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                self.widget:rerender()
            end
        end
    )

    self.diagnostics_list = DiagnosticsList:new(
        self.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                self.widget:close_optional_window("diagnostics")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:rerender()
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:rerender()
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

function SessionManager:_handle_connection_error()
    if self._destroyed then
        return
    end

    self._connection_error = true
    self._session_creation_failed = true
    SessionManager._resolve_session_ready_callbacks(self, false)
    self.is_generating = false
    self.status_animation:stop()
    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(
            "⚠️ Failed to connect to "
                .. self.agent.provider_config.name
                .. ". Check that the provider is"
                .. " installed and try again"
                .. " with a new session."
        )
    )
end

--- @param succeeded boolean
function SessionManager:_resolve_session_ready_callbacks(succeeded)
    local callbacks = self._session_ready_callbacks or {}
    self._session_ready_callbacks = {}

    if #callbacks == 0 then
        return
    end

    vim.schedule(function()
        if self._destroyed then
            return
        end

        for _, callback in ipairs(callbacks) do
            callback(succeeded)
        end
    end)
end

--- Fires on the next tick when the session is already ready.
--- @param callback fun(session: agentic.SessionManager)
--- @param on_failure fun(session: agentic.SessionManager)|nil
function SessionManager:on_session_ready(callback, on_failure)
    if self.session_id then
        Logger.debug(
            "on_session_ready: session already ready, scheduling callback immediately"
        )
        vim.schedule(function()
            if self._destroyed then
                return
            end

            callback(self)
        end)
        return
    end

    if self._connection_error or self._session_creation_failed then
        if on_failure then
            vim.schedule(function()
                if not self._destroyed then
                    on_failure(self)
                end
            end)
        end
        return
    end

    Logger.debug(
        "on_session_ready: queueing callback, will fire when session ready"
    )
    table.insert(self._session_ready_callbacks, function(succeeded)
        if succeeded then
            callback(self)
        elseif on_failure then
            on_failure(self)
        end
    end)
end

--- @param acp_session_id string
--- @return boolean owns_id
function SessionManager:has_acp_session_id(acp_session_id)
    return self.session_id == acp_session_id
        or (self._starter and self._starter:has_session_id(acp_session_id))
end

--- @param acp_session_id string
--- @return boolean owns_ready_id
function SessionManager:owns_ready_acp_session(acp_session_id)
    return not self._destroyed
        and not is_replaying(self)
        and self.session_id == acp_session_id
end

--- Notifies the user with the reason when it answers false.
--- @return boolean can_submit
function SessionManager:can_submit_prompt()
    if self._connection_error then
        Logger.notify(
            "Provider connection failed. Start a new session.",
            vim.log.levels.ERROR
        )
        return false
    end

    if not self.session_id then
        Logger.notify(
            "Session not ready. Wait for initialization to complete.",
            vim.log.levels.WARN
        )
        return false
    end

    return true
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    if update.sessionUpdate == "user_message_chunk" then
        if is_replaying(self) then
            local text = update.content
                and update.content.type == "text"
                and update.content.text
            if text and text ~= "" then
                self.message_writer:write_restoring_message(
                    ACPPayloads.generate_user_message(text)
                )
                self.chat_history:add_message({
                    type = "user",
                    text = text,
                    timestamp = os.time(),
                    provider_name = self.agent.provider_config.name,
                })
            end
        end
    elseif update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "agent_message_chunk" then
        self:_start_spinner("generating")
        self.message_writer:write_message_chunk(update)

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "agent",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self:_start_spinner("thinking")
        self.message_writer:write_message_chunk(update)

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "thought",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "available_commands_update" then
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            self:_set_mode_to_chat_header(update.currentModeId)
            self.widget:schedule_header_refresh()
        end
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        self.session_state:set_usage(update)
        self.widget:schedule_header_refresh()
    elseif update.sessionUpdate == "session_info_update" then
        -- Session metadata is currently informational only
    else
        -- TODO: Move this to Logger from notify to debug when confidence is high
        Logger.notify(
            "Unknown session update type: "
                .. tostring(
                    --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end

    -- Hooks reflect live activity only; a restore replays historical updates.
    if is_replaying(self) then
        return
    end

    --- @type agentic.UserConfig.SessionUpdateData
    local hook_data = {
        session_id = self.session_id,
        session_key = self.session_key,
        tab_page_id = self.widget:get_visible_tab_id(),
        update = update,
    }
    Hooks.invoke("on_session_update", hook_data)
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call(tool_call)
    if self.message_writer.tool_call_blocks[tool_call.tool_call_id] then
        -- Some providers (Mistral) send several `tool_call` for one id.
        self:_on_tool_call_update(tool_call)
        return
    end

    self.message_writer:write_tool_call_block(tool_call)

    local merged = self.message_writer.tool_call_blocks[tool_call.tool_call_id]
    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_msg = vim.tbl_deep_extend("force", {
        type = "tool_call",
    }, merged)

    self.chat_history:add_message(tool_msg)
end

--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call_update(tool_call_update)
    if
        not self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]
    then
        self:_on_tool_call(tool_call_update)
    else
        self.message_writer:update_tool_call_block(tool_call_update)

        local merged =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]
        --- @type agentic.ui.ChatHistory.ToolCall
        local tool_msg = vim.tbl_deep_extend("force", {
            type = "tool_call",
        }, merged)

        self.chat_history:update_tool_call(
            tool_call_update.tool_call_id,
            tool_msg
        )
    end

    local tracker =
        self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

    local is_terminal = tool_call_update.status == "completed"
        or tool_call_update.status == "failed"
    if is_terminal then
        local is_rejection = tool_call_update.status == "failed"
        self.diff_coordinator:clear(tool_call_update.tool_call_id, is_rejection)
    end

    if
        tool_call_update.status == "completed"
        and tracker
        and tracker.kind
        and ACPPayloads.FILE_MUTATING_KINDS[tracker.kind]
    then
        DiffPreview.cleanup_suggestion_buffer(
            tracker.file_path,
            self.diff_coordinator.diff_state
        )
    end

    -- Terminal status: clear the inline permission buttons.
    if
        tool_call_update.status == "failed"
        or tool_call_update.status == "completed"
    then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    if tool_call_update.status == "completed" then
        if
            tracker
            and tracker.kind
            and ACPPayloads.FILE_MUTATING_KINDS[tracker.kind]
        then
            vim.cmd.checktime()

            -- Skip the hook during restore replay: the provider replays
            -- historical tool calls as "completed" but no write happened now.
            if
                not is_replaying(self)
                and type(tracker.file_path) == "string"
                and tracker.file_path ~= ""
            then
                local abs_path = FileSystem.to_absolute_path(tracker.file_path)
                local raw_bufnr = vim.fn.bufnr(abs_path)
                local is_loaded = raw_bufnr ~= -1
                    and vim.api.nvim_buf_is_loaded(raw_bufnr)
                --- @type number|nil
                local bufnr = is_loaded and raw_bufnr or nil
                --- @type agentic.UserConfig.FileEditData
                local hook_data = {
                    filepath = abs_path,
                    session_id = self.session_id,
                    session_key = self.session_key,
                    tab_page_id = self.widget:get_visible_tab_id(),
                    bufnr = bufnr,
                }
                Hooks.invoke("on_file_edit", hook_data)
            end
        end
    end

    if not self.permission_manager:has_pending() then
        self:_start_spinner("generating")
    end
end

--- NOTE: This is used by users inside hooks, moving/renaming this is a breaking change!
function SessionManager:schedule_header_refresh()
    self.widget:schedule_header_refresh()
end

--- @param mode_id string
function SessionManager:_set_mode_to_chat_header(mode_id)
    local mode_name = self.config_options:get_mode_name(mode_id)
    self.widget:render_header(
        "chat",
        string.format("Mode: %s", mode_name or mode_id)
    )
end

--- @param input_text string
--- @return boolean submitted
function SessionManager:_handle_input_submit(input_text)
    -- BEFORE the submit guard, so `/new` escapes a stuck session.
    if input_text:match("^/new%s") or input_text:match("^/new$") then
        require("agentic.session_registry").replace(
            self,
            self.provider_name,
            { kind = "new" },
            { agent = self.agent }
        )
        return true
    end

    self.todo_list:close_if_all_completed()

    if not self:can_submit_prompt() then
        return false
    end

    --- Sent to the agent, not written to the chat
    --- @type agentic.acp.Content[]
    local prompt = {}

    if self.history_to_send then
        ChatHistory.prepend_restored_messages(self.history_to_send, prompt)
        self.history_to_send = nil
    end

    -- First submit only, so the picker label stays stable.
    if self.chat_history.title == "" then
        self.chat_history.title = title_from_prompt(input_text)
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    -- After the user text, so the resume picker shows the prompt.
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = EnvironmentInfo.get_system_info(),
        })
    end

    --- Written to the chat widget
    local message_lines = {}

    table.insert(message_lines, input_text)

    if not self.code_selection:is_empty() then
        local code_selection_lines, code_selection_prompt =
            self.code_selection:to_prompt()
        vim.list_extend(message_lines, code_selection_lines)
        vim.list_extend(prompt, code_selection_prompt)
    end

    if not self.file_list:is_empty() then
        local file_list_lines, file_list_prompt = self.file_list:to_prompt()
        vim.list_extend(message_lines, file_list_lines)
        vim.list_extend(prompt, file_list_prompt)
    end

    if not self.diagnostics_list:is_empty() then
        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local diagnostics_lines, diagnostics_prompt =
            self.diagnostics_list:to_prompt(chat_width)
        vim.list_extend(message_lines, diagnostics_lines)
        vim.list_extend(prompt, diagnostics_prompt)
    end

    local user_message = ACPPayloads.generate_user_message(message_lines)
    self.message_writer:write_message(user_message)

    --- @type agentic.ui.ChatHistory.UserMessage
    local user_msg = {
        type = "user",
        text = input_text,
        timestamp = os.time(),
        provider_name = self.agent.provider_config.name,
    }
    self.chat_history:add_message(user_msg)

    self.status_animation:start("thinking")

    --- @type agentic.UserConfig.PromptSubmitData
    local prompt_hook_data = {
        prompt = input_text,
        session_id = self.session_id,
        session_key = self.session_key,
        tab_page_id = self.widget:get_visible_tab_id(),
    }
    Hooks.invoke("on_prompt_submit", prompt_hook_data)

    -- Captured, NOT re-read below: this is the staleness guard.
    local session_id = self.session_id

    self.is_generating = true

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        vim.schedule(function()
            if self._destroyed or self.session_id ~= session_id then
                return
            end

            self.message_writer:write_finish_message(response, err)
            self.status_animation:stop()
            self.is_generating = false

            --- @type agentic.UserConfig.ResponseCompleteData
            local response_hook_data = {
                session_id = session_id --[[@as string]],
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
                success = err == nil,
                error = err,
            }
            Hooks.invoke("on_response_complete", response_hook_data)
        end)
    end)

    return true
end

--- Every handler re-checks `_destroyed` at RUN time: `__with_subscriber` schedules
--- the call, so dropping the subscriber cannot un-queue an already-queued callback.
--- @return agentic.acp.ClientHandlers handlers
function SessionManager:_build_handlers()
    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            if self._destroyed then
                return
            end

            Logger.debug("Agent error: ", err)

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message({
                    "🐞 Agent Error:",
                    "",
                    vim.inspect(err),
                })
            )
        end,

        on_session_update = function(update)
            if self._destroyed then
                return
            end

            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            if self._destroyed then
                return
            end

            self:_on_tool_call(tool_call)
        end,

        on_tool_call_update = function(tool_call_update)
            if self._destroyed then
                return
            end

            self:_on_tool_call_update(tool_call_update)
        end,

        on_request_permission = function(request, callback)
            if self._destroyed then
                -- The ONLY handler that owes a JSON-RPC response, so it cannot
                -- return silently: the provider subprocess outlives this session.
                callback(nil)
                return
            end

            Hooks.invoke("on_request_permission", {
                request = request,
                session_id = self.session_id,
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
            })

            self.status_animation:stop()

            local function wrapped_callback(option_id)
                callback(option_id)

                local is_rejection = option_id == "reject_once"
                    or option_id == "reject_always"
                self.diff_coordinator:clear(
                    request.toolCall.toolCallId,
                    is_rejection
                )

                if not self.permission_manager:has_pending() then
                    self:_start_spinner("generating")
                end
            end

            self.diff_coordinator:show(request.toolCall.toolCallId)
            self.permission_manager:add_request(request, wrapped_callback)
        end,
    }

    return handlers
end

--- @param response agentic.acp.SessionCreationResponse|agentic.acp.LoadSessionResponse
function SessionManager:_apply_start_metadata(response)
    if response.configOptions then
        Logger.debug("Provider announce configOptions")
        self:_handle_new_config_options(response.configOptions)
        return
    end

    if response.modes then
        Logger.debug("Provider announce legacy mode")
        self.config_options:set_legacy_modes(response.modes)
        self:_set_mode_to_chat_header(response.modes.currentModeId)
    end

    if response.models then
        Logger.debug("Provider announce legacy models")
        self.config_options:set_legacy_models(response.models)
    end
end

function SessionManager:_apply_initial_options()
    local function apply_initial_thought_level()
        self.config_options:set_initial_thought_level(
            self.agent.provider_config.default_thought_level
        )
    end

    local will_change_model = self.config_options:set_initial_model(
        self.agent.provider_config.initial_model,
        apply_initial_thought_level
    )

    self.config_options:set_initial_mode(
        self.agent.provider_config.default_mode
    )

    if not will_change_model then
        apply_initial_thought_level()
    end
end

--- @param spec agentic.SessionStartSpec
--- @param callback fun(session: agentic.SessionManager, err: agentic.acp.ACPError|nil)|nil
function SessionManager:start(spec, callback)
    if self._start_called then
        if callback then
            vim.schedule(function()
                callback(self, {
                    code = -32600,
                    message = "Session manager can only be started once",
                })
            end)
        end
        return
    end

    self._start_called = true
    self._session_creation_failed = false
    self.status_animation:start("busy")

    if spec.kind == "load" then
        local agent_info = self.agent.agent_info
        local welcome_message = self.message_writer:generate_welcome_header(
            self.agent.provider_config.name,
            spec.session_id,
            agent_info and agent_info.version,
            spec.timestamp
        )
        self.message_writer:write_structural_message(
            ACPPayloads.generate_user_message(welcome_message)
        )
    end

    self._starter:start(spec, self:_build_handlers(), function(result, err)
        if self._destroyed then
            if result then
                self.agent:cancel_session(result.session_id)
            end
            if callback then
                callback(self, err)
            end
            return
        end

        self.status_animation:stop()

        if err or not result then
            self.session_id = nil
            self._session_creation_failed = true
            if spec.kind == "new" then
                --- @type agentic.UserConfig.CreateSessionResponseData
                local hook_data = {
                    session_id = nil,
                    session_key = self.session_key,
                    tab_page_id = self.widget:get_visible_tab_id(),
                    response = nil,
                    err = err,
                }
                Hooks.invoke("on_create_session_response", hook_data)
            else
                Logger.notify(
                    "Failed to load session: "
                        .. (err and err.message or "unknown error"),
                    vim.log.levels.ERROR
                )
            end
            SessionManager._resolve_session_ready_callbacks(self, false)
            if callback then
                callback(self, err)
            end
            return
        end

        self.session_id = result.session_id
        self.chat_history.session_id = result.session_id
        self.chat_history.timestamp = os.time()
        self:_apply_start_metadata(result.response)

        if result.kind == "new" then
            self._is_first_message = true
            self:_apply_initial_options()
        else
            self._is_first_message = false
            self.chat_history.title = spec.title or ""
        end

        local agent_info = self.agent.agent_info
        if result.kind == "new" then
            local welcome_message = self.message_writer:generate_welcome_header(
                self.agent.provider_config.name,
                result.session_id,
                agent_info and agent_info.version,
                spec.timestamp
            )
            self.message_writer:write_structural_message(
                ACPPayloads.generate_user_message(welcome_message)
            )
        else
            local finish_message = string.format(
                "\n### %s Session restored - %s\n-----",
                Config.message_icons.finished,
                os.date("%Y-%m-%d %H:%M:%S")
            )
            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(finish_message)
            )
        end

        if result.kind == "new" then
            --- @type agentic.UserConfig.CreateSessionResponseData
            local hook_data = {
                session_id = result.session_id,
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
                --- @diagnostic disable-next-line: assign-type-mismatch
                response = result.response,
                err = nil,
            }
            Hooks.invoke("on_create_session_response", hook_data)
        end

        SessionManager._resolve_session_ready_callbacks(self, true)
        if callback then
            callback(self, nil)
        end
    end)
end

--- @param state agentic.Theme.SpinnerState
function SessionManager:_start_spinner(state)
    if self.is_generating then
        self.status_animation:start(state)
    end
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self.code_selection.get_selected_text()

    if selection then
        self.code_selection:add(selection)
        return true
    end

    return false
end

--- @param buf integer|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @return integer count
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @return integer count
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param new_config_options agentic.acp.AnyConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)
    local mode_id = self.config_options:get_mode_id()
    if mode_id then
        self:_set_mode_to_chat_header(mode_id)
    end

    self.widget:schedule_header_refresh()
end

function SessionManager:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    if self._starter then
        self._starter:cancel()
    end
    if self.session_id and self.agent and self.agent.cancel_session then
        self.agent:cancel_session(self.session_id)
        self.session_id = nil
    end
    self.is_generating = false
    if self.status_animation then
        self.status_animation:stop()
    end
    if self.permission_manager then
        self.permission_manager:clear()
    end
    self._session_ready_callbacks = {}
    self._pending_replacement_sources = nil
    self.history_to_send = nil
    if self.chat_history then
        self.chat_history.session_id = nil
        self.chat_history.title = ""
        self.chat_history.timestamp = 0
        self.chat_history.messages = {}
    end
    if self.file_list then
        self.file_list:clear()
    end
    if self.code_selection then
        self.code_selection:clear()
    end
    if self.diagnostics_list then
        self.diagnostics_list:clear()
    end
    if self.todo_list then
        self.todo_list:clear()
    end
    if self.config_options then
        self.config_options:clear()
    end
    if self.session_state then
        self.session_state:clear()
    end
    if self.widget.buf_nrs and self.widget.buf_nrs.input then
        SlashCommands.setCommands(self.widget.buf_nrs.input, {})
    end
    self.widget:destroy()
    if self.message_writer then
        self.message_writer:destroy()
    end
end

return SessionManager
