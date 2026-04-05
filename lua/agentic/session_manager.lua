-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SlashCommands = require("agentic.acp.slash_commands")

--- @class agentic._SessionManagerPrivate
local P = {}

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

--- Safely invoke a user-configured hook
--- @param hook_name "on_prompt_submit" | "on_response_complete" | "on_session_update"
--- @param data table
function P.invoke_hook(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if hook and type(hook) == "function" then
        vim.schedule(function()
            local ok, err = pcall(hook, data)
            if not ok then
                Logger.debug(
                    string.format("Hook '%s' error: %s", hook_name, err)
                )
            end
        end)
    end
end

--- @class agentic.SessionManager
--- @field session_id? string
--- @field tab_page_id integer
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
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field history_to_send agentic.ui.ChatHistory.Message[]|nil
--- @field _is_restoring_session boolean
--- @field _connection_error boolean
--- @field _session_ready_callbacks fun()[]
local SessionManager = {}
SessionManager.__index = SessionManager

--- @param provider_name string
--- @param session_id string|nil
--- @param version string|nil
--- @param timestamp string|integer|nil Formatted string, unix timestamp, or nil for now
--- @return string header
function SessionManager._generate_welcome_header(
    provider_name,
    session_id,
    version,
    timestamp
)
    local date_str
    if type(timestamp) == "string" then
        date_str = timestamp
    else
        date_str = os.date("%Y-%m-%d %H:%M:%S", timestamp)
    end
    local name = provider_name
    if version then
        name = name .. " v" .. version
    end
    return string.format(
        "# Agentic - %s\n- session id: %s\n- %s\n--- --",
        name,
        session_id or "unknown",
        date_str
    )
end

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _is_restoring_session = false,
        _connection_error = false,
        history_to_send = nil,
        _session_ready_callbacks = {},
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            -- Guard: cached client may be dead
            if
                self.agent.state == "error"
                or self.agent.state == "disconnected"
            then
                self:_handle_connection_error()
                return
            end
            self:new_session()
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        return self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.message_writer:set_provider_name(self.agent.provider_config.name)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.status_animation:start("busy")

    -- Check for sync failure during ACPClient construction
    -- Guard with _connection_error to avoid double-fire if async callback already ran
    if
        not self._connection_error
        and (self.agent.state == "error" or self.agent.state == "disconnected")
    then
        vim.schedule(function()
            if not self._connection_error then
                self:_handle_connection_error()
            end
        end)
    end

    self.permission_manager = PermissionManager:new(self.message_writer)

    FilePicker:new(self.widget.buf_nrs.input)
    SlashCommands.setup_completion(self.widget.buf_nrs.input)

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
        function(mode_id, is_legacy)
            self:_handle_mode_change(mode_id, is_legacy)
        end,
        function(model_id, is_legacy)
            self:_handle_model_change(model_id, is_legacy)
        end
    )

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:show({ focus_prompt = false })
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
                self.widget:show({ focus_prompt = false })
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
                -- show() opens layouts but does not update the diagnostics header count
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

--- Handle provider connection failure.
--- Stops busy animation and writes error to chat buffer.
function SessionManager:_handle_connection_error()
    self._connection_error = true
    self._session_ready_callbacks = {}
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

--- Register callback for when ACP session is ready.
--- Fires immediately (via vim.schedule) if session
--- already exists.
--- @param callback fun(session: agentic.SessionManager)
function SessionManager:on_session_ready(callback)
    if self.session_id then
        Logger.debug(
            "on_session_ready: session already ready, scheduling callback immediately"
        )
        vim.schedule(function()
            callback(self)
        end)
        return
    end

    Logger.debug(
        "on_session_ready: queueing callback, will fire when session ready"
    )
    table.insert(self._session_ready_callbacks, function()
        callback(self)
    end)
end

--- Check if a prompt can be submitted to the session.
--- Returns false if session not ready, generating, or
--- restoring. Notifies user of the reason.
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

    if self._is_restoring_session then
        Logger.notify(
            "Session is restoring. Please wait...",
            vim.log.levels.WARN
        )
        return false
    end

    if self.is_generating then
        Logger.notify(
            "Agent is still processing. Please wait...",
            vim.log.levels.WARN
        )
        return false
    end

    return true
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    if update.sessionUpdate == "user_message_chunk" then
        if self._is_restoring_session then
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
        self.status_animation:start("generating")
        self.message_writer:write_message_chunk(update)

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "agent",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self.status_animation:start("thinking")
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
        end
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        -- Usage updates contain token/cost information - currently informational only
        -- Fields: used (tokens), size (context window), cost (optional: amount, currency)
        -- Keeping silent for now to avoid "press any key" prompts on large JSON output
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

    -- This is being done after handling specific updates but one could argue
    -- there should be pre/post hooks for everything.
    P.invoke_hook("on_session_update", {
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
        update = update,
    })
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call(tool_call)
    if self.message_writer.tool_call_blocks[tool_call.tool_call_id] then
        -- fallback for bad ACP implementations which sends multiple `tool_call` with different data (initially added for Mistral)
        self:_on_tool_call_update(tool_call)
        return
    end

    self.message_writer:write_tool_call_block(tool_call)

    -- Store merged block from MessageWriter (has normalized/accumulated fields)
    local merged = self.message_writer.tool_call_blocks[tool_call.tool_call_id]
    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_msg = vim.tbl_deep_extend("force", {
        type = "tool_call",
    }, merged)

    self.chat_history:add_message(tool_msg)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_on_tool_call_update(tool_call_update)
    if
        not self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]
    then
        self:_on_tool_call(tool_call_update)
    else
        self.message_writer:update_tool_call_block(tool_call_update)

        -- Store merged block from MessageWriter (has accumulated body and normalized fields)
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

    -- pre-emptively clear diff preview when tool call update is received, as it's either done or failed
    local is_rejection = tool_call_update.status == "failed"
    self:_clear_diff_in_buffer(tool_call_update.tool_call_id, is_rejection)

    -- Remove the permission request if the tool call failed before user granted it
    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    -- Reload buffers when file-mutating tool calls complete
    if tool_call_update.status == "completed" then
        local tracker =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

        if tracker and tracker.kind and FILE_MUTATING_KINDS[tracker.kind] then
            vim.cmd.checktime()

            DiffPreview.cleanup_suggestion_buffer(tracker.file_path)
        end
    end

    if
        not self.permission_manager.current_request
        and #self.permission_manager.queue == 0
    then
        self.status_animation:start("generating")
    end
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_mode_change(mode_id, is_legacy)
    if not self.session_id then
        return
    end

    local request_session_id = self.session_id

    local function callback(result, err)
        if self.session_id ~= request_session_id then
            Logger.debug("Stale mode change response, ignoring")
            return
        end

        if err then
            Logger.notify(
                string.format(
                    "Failed to change mode to '%s': %s",
                    mode_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- needed for backward compatibility
            self.config_options.legacy_agent_modes.current_mode_id = mode_id

            if result and result.configOptions then
                Logger.debug("received result after setting mode")
                self:_handle_new_config_options(result.configOptions)
            end

            self:_set_mode_to_chat_header(mode_id)

            local mode_name = self.config_options:get_mode_name(mode_id)
            Logger.notify(
                "Mode changed to: " .. mode_name,
                vim.log.levels.INFO,
                {
                    title = "Agentic Mode changed",
                }
            )
        end
    end

    if is_legacy then
        self.agent:set_mode(self.session_id, mode_id, callback)
    else
        self.agent:set_config_option(self.session_id, "mode", mode_id, callback)
    end
end

--- Send the newly selected model to the agent
--- @param model_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_model_change(model_id, is_legacy)
    if not self.session_id then
        return
    end

    local request_session_id = self.session_id

    local callback = function(result, err)
        if self.session_id ~= request_session_id then
            Logger.debug("Stale model change response, ignoring")
            return
        end

        if err then
            Logger.notify(
                string.format(
                    "Failed to change model to '%s': %s",
                    model_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- Always update legacy state on success (mirrors _handle_mode_change pattern)
            self.config_options.legacy_agent_models.current_model_id = model_id

            if result and result.configOptions then
                Logger.debug("received result after setting model")
                self:_handle_new_config_options(result.configOptions)
            end

            Logger.notify(
                "Model changed to: " .. model_id,
                vim.log.levels.INFO,
                { title = "Agentic Model changed" }
            )
        end
    end

    if is_legacy then
        self.agent:set_model(self.session_id, model_id, callback)
    else
        self.agent:set_config_option(
            self.session_id,
            "model",
            model_id,
            callback
        )
    end
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
    self.todo_list:close_if_all_completed()

    -- Intercept /new command BEFORE the generation guard so users can
    -- escape a stuck state from the chat input
    if input_text:match("^/new%s") or input_text:match("^/new$") then
        self:new_session()
        return true
    end

    -- Guard: cannot submit if session not ready or generating
    if not self:can_submit_prompt() then
        return false
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- If restored/switched session, prepend history on first submit
    if self.history_to_send then
        self.chat_history.title = input_text -- Update title for restored session
        ChatHistory.prepend_restored_messages(self.history_to_send, prompt)
        self.history_to_send = nil
    elseif self.chat_history.title == "" then
        self.chat_history.title = input_text -- Set title for new session
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    -- Add system info on first message only (after user text so resume picker shows the prompt)
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = self:_get_system_info(),
        })
    end

    --- The message to be written to the chat widget
    local message_lines = {}

    table.insert(message_lines, input_text)

    if not self.code_selection:is_empty() then
        table.insert(message_lines, "\n- **Selected code**:\n")

        table.insert(prompt, {
            type = "text",
            text = table.concat({
                "IMPORTANT: Focus and respect the line numbers provided in the <line_start> and <line_end> tags for each <selected_code> tag.",
                "The selection shows ONLY the specified line range, not the entire file!",
                "The file may contain duplicated content of the selected snippet.",
                "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
                "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
            }, "\n"),
        })

        local selections = self.code_selection:get_selections()
        self.code_selection:clear()

        for _, selection in ipairs(selections) do
            if selection and #selection.lines > 0 then
                -- Add line numbers to each line in the snippet
                local numbered_lines = {}
                for i, line in ipairs(selection.lines) do
                    local line_num = selection.start_line + i - 1
                    table.insert(
                        numbered_lines,
                        string.format("Line %d: %s", line_num, line)
                    )
                end
                local numbered_snippet = table.concat(numbered_lines, "\n")

                table.insert(prompt, {
                    type = "text",
                    text = string.format(
                        table.concat({
                            "<selected_code>",
                            "<path>%s</path>",
                            "<line_start>%s</line_start>",
                            "<line_end>%s</line_end>",
                            "<snippet>",
                            "%s",
                            "</snippet>",
                            "</selected_code>",
                        }, "\n"),
                        FileSystem.to_absolute_path(selection.file_path),
                        selection.start_line,
                        selection.end_line,
                        numbered_snippet
                    ),
                })

                table.insert(
                    message_lines,
                    string.format(
                        "```%s %s#L%d-L%d\n%s\n```",
                        selection.file_type,
                        selection.file_path,
                        selection.start_line,
                        selection.end_line,
                        table.concat(selection.lines, "\n")
                    )
                )
            end
        end
    end

    if not self.file_list:is_empty() then
        table.insert(message_lines, "\n- **Referenced files**:")

        local files = self.file_list:get_files()
        self.file_list:clear()

        for _, file_path in ipairs(files) do
            table.insert(prompt, ACPPayloads.create_file_content(file_path))

            table.insert(
                message_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end
    end

    if not self.diagnostics_list:is_empty() then
        table.insert(message_lines, "\n- **Diagnostics**:")

        local diagnostics = self.diagnostics_list:get_diagnostics()
        self.diagnostics_list:clear()

        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local DiagnosticsContext = require("agentic.ui.diagnostics_context")

        local formatted_diagnostics =
            DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

        for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
            table.insert(prompt, prompt_entry)
        end

        for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
            table.insert(message_lines, summary_line)
        end
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

    P.invoke_hook("on_prompt_submit", {
        prompt = input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id

    self.is_generating = true

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        vim.schedule(function()
            -- Guard: skip stale response if session changed (cancel/restore/new)
            if self.session_id ~= session_id then
                return
            end

            self.is_generating = false

            local finish_message = string.format(
                "\n### 🏁 %s\n-----",
                os.date("%Y-%m-%d %H:%M:%S")
            )

            if err then
                finish_message = string.format(
                    "\n### ❌ Agent finished with error: %s\n%s",
                    vim.inspect(err),
                    finish_message
                )
            elseif response and response.stopReason == "cancelled" then
                finish_message = string.format(
                    "\n### 🛑 Generation stopped by the user request\n%s",
                    finish_message
                )
            end

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(finish_message)
            )

            self.status_animation:stop()

            P.invoke_hook("on_response_complete", {
                session_id = session_id,
                tab_page_id = tab_page_id,
                success = err == nil,
                error = err,
            })
        end)
    end)

    return true
end

--- Build the standard ACP client handlers for session subscriptions
--- @return agentic.acp.ClientHandlers handlers
function SessionManager:_build_handlers()
    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
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
            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            self:_on_tool_call(tool_call)
        end,

        on_tool_call_update = function(tool_call_update)
            self:_on_tool_call_update(tool_call_update)
        end,

        on_request_permission = function(request, callback)
            self.status_animation:stop()

            local function wrapped_callback(option_id)
                callback(option_id)

                local is_rejection = option_id == "reject_once"
                    or option_id == "reject_always"
                self:_clear_diff_in_buffer(
                    request.toolCall.toolCallId,
                    is_rejection
                )

                if
                    not self.permission_manager.current_request
                    and #self.permission_manager.queue == 0
                then
                    self.status_animation:start("generating")
                end
            end

            self:_show_diff_in_buffer(request.toolCall.toolCallId)
            self.permission_manager:add_request(request, wrapped_callback)
        end,
    }

    return handlers
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun(), timestamp?: string|integer}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        self:_cancel_session()
    end

    self.status_animation:start("busy")

    local handlers = self:_build_handlers()

    self.agent:create_session(handlers, function(response, err)
        self.status_animation:stop()

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            return
        end

        self.session_id = response.sessionId
        self.chat_history.session_id = response.sessionId
        self.chat_history.timestamp = os.time()

        if response.configOptions then
            Logger.debug("Provider announce configOptions")
            self:_handle_new_config_options(response.configOptions)
        else
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

        self.config_options:set_initial_model(
            self.agent.provider_config.initial_model,
            function(model, is_legacy)
                self:_handle_model_change(model, is_legacy)
            end
        )

        self.config_options:set_initial_mode(
            self.agent.provider_config.default_mode,
            function(mode, is_legacy)
                self:_handle_mode_change(mode, is_legacy)
            end
        )

        -- Reset first message flag for new session (skip when restoring)
        if not restore_mode then
            self._is_first_message = true
        end

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        -- For restore: write welcome first, then replay via on_created
        vim.schedule(function()
            local agent_info = self.agent.agent_info
            local welcome_message = SessionManager._generate_welcome_header(
                self.agent.provider_config.name,
                self.session_id,
                agent_info and agent_info.version,
                opts.timestamp
            )

            self.message_writer:write_structural_message(
                ACPPayloads.generate_user_message(welcome_message)
            )

            -- Invoke on_created callback after welcome message is written
            if on_created then
                on_created()
            end

            -- Fire session ready callbacks after welcome banner
            if #self._session_ready_callbacks > 0 then
                Logger.debug(
                    "Firing "
                        .. tostring(#self._session_ready_callbacks)
                        .. " session ready callbacks"
                )
            end
            for _, cb in ipairs(self._session_ready_callbacks) do
                cb()
            end
            self._session_ready_callbacks = {}
        end)
    end)
end

function SessionManager:_cancel_session()
    self._is_restoring_session = false
    self.is_generating = false
    self.status_animation:stop()

    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()
    end

    self.session_id = nil
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})

    self.chat_history = ChatHistory:new()
    self.history_to_send = nil
    self.message_writer:reset_sender_tracking()
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

--- Add diagnostics at the current cursor line to context
--- @param bufnr integer|nil Buffer number to get diagnostics from, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- Add all diagnostics from the current buffer to context
--- @param bufnr integer|nil Buffer number, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param tool_call_id string
function SessionManager:_show_diff_in_buffer(tool_call_id)
    -- Only show diff if enabled by user config,
    -- and cursor is in the same tabpage as this session to avoid disruption
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.tab_page_id
    then
        return
    end

    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if
        not tracker
        or tracker.kind ~= "edit"
        or tracker.diff == nil
        or not tracker.file_path
    then
        return
    end

    DiffPreview.show_diff({
        file_path = tracker.file_path,
        diff = tracker.diff,
        get_winid = function(bufnr)
            local winid = self.widget:find_first_non_widget_window()
            if not winid then
                return self.widget:open_left_window(bufnr)
            end
            local ok, err = pcall(vim.api.nvim_win_set_buf, winid, bufnr)

            if not ok then
                Logger.notify(
                    "Failed to set buffer in window: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return nil
            end
            return winid
        end,
    })
end

--- @param tool_call_id string
--- @param is_rejection boolean|nil
function SessionManager:_clear_diff_in_buffer(tool_call_id, is_rejection)
    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if
        not tracker
        or tracker.kind ~= "edit"
        or tracker.diff == nil
        or not tracker.file_path
    then
        return
    end

    DiffPreview.clear_diff(tracker.file_path, is_rejection)
end

--- @param new_config_options agentic.acp.ConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)

    if self.config_options.mode and self.config_options.mode.currentValue then
        self:_set_mode_to_chat_header(self.config_options.mode.currentValue)
    end
end

function SessionManager:_get_system_info()
    local os_name = vim.uv.os_uname().sysname
    local os_version = vim.uv.os_uname().release
    local os_machine = vim.uv.os_uname().machine
    local shell = os.getenv("SHELL")
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        [[
- Platform: %s-%s-%s
- Shell: %s
- Editor: Neovim %s
- Current date: %s]],
        os_name,
        os_version,
        os_machine,
        shell,
        neovim_version,
        today
    )

    local project_root = vim.uv.cwd()

    local git_root = vim.fs.root(project_root or 0, ".git")
    if git_root then
        project_root = git_root
        res = res .. "\n- This is a Git repository."

        local branch =
            vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
        if vim.v.shell_error == 0 and branch ~= "" then
            res = res .. string.format("\n- Current branch: %s", branch)
        end

        local changed = vim.fn.system("git status --porcelain"):gsub("\n$", "")
        if vim.v.shell_error == 0 and changed ~= "" then
            local files = vim.split(changed, "\n")
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = vim.fn
            .system("git log -3 --oneline --format='%h (%ar) %an: %s'")
            :gsub("\n$", "")
        if vim.v.shell_error == 0 and commits ~= "" then
            local commit_lines = vim.split(commits, "\n")
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    if project_root then
        res = res .. string.format("\n- Project root: %s", project_root)
    end

    res = "<environment_info>\n" .. res .. "\n</environment_info>"
    return res
end

function SessionManager:destroy()
    self:_cancel_session()
    self.widget:destroy()
end

--- Load an existing ACP session by ID, subscribing to its updates
--- @param session_id string
--- @param title string|nil
--- @param timestamp string|integer|nil Timestamp for the banner; defaults to now
function SessionManager:load_acp_session(session_id, title, timestamp)
    local caps = self.agent.agent_capabilities
    if not caps or not caps.loadSession then
        Logger.notify(
            "Agent does not support loading sessions",
            vim.log.levels.WARN
        )
        return
    end

    -- Preserve config_options (mode/model) across cancel — session/load doesn't
    -- re-send them and they belong to the agent instance, not the session.
    -- Save snapshots, NOT object references — :clear() mutates in-place.
    local saved_config = {
        mode = self.config_options.mode,
        model = self.config_options.model,
        thought_level = self.config_options.thought_level,
        legacy_modes = self.config_options.legacy_agent_modes:save(),
        legacy_models = self.config_options.legacy_agent_models:save(),
    }

    self:_cancel_session()

    self.config_options.mode = saved_config.mode
    self.config_options.model = saved_config.model
    self.config_options.thought_level = saved_config.thought_level
    self.config_options.legacy_agent_modes:restore(saved_config.legacy_modes)
    self.config_options.legacy_agent_models:restore(saved_config.legacy_models)

    self._is_restoring_session = true
    self.status_animation:start("busy")

    -- Write banner before loading so it appears at top of cleared buffer
    local agent_info = self.agent.agent_info
    local welcome_message = SessionManager._generate_welcome_header(
        self.agent.provider_config.name,
        session_id,
        agent_info and agent_info.version,
        timestamp
    )
    self.message_writer:write_structural_message(
        ACPPayloads.generate_user_message(welcome_message)
    )

    local handlers = self:_build_handlers()
    local cwd = vim.fn.getcwd()

    self.agent:load_session(session_id, cwd, {}, handlers, function(err)
        -- vim.schedule to run AFTER deferred session update notifications
        -- (user_message_chunk etc. are routed via __with_subscriber → vim.schedule)
        vim.schedule(function()
            self._is_restoring_session = false
            self.status_animation:stop()

            -- Guard: if a new session was created while the load was in flight,
            -- don't stomp the new session's state
            if self.session_id ~= nil then
                return
            end

            if err then
                local error_text = err.message or "unknown error"
                Logger.notify(
                    "Failed to load session: " .. error_text,
                    vim.log.levels.ERROR
                )
                self.widget:clear()
                self.message_writer:write_message(
                    ACPPayloads.generate_agent_message(
                        "### ❌ Failed to restore session\n\n" .. error_text
                    )
                )
                return
            end

            self.session_id = session_id
            self.chat_history.session_id = session_id
            self.chat_history.title = title or ""
            self.chat_history.timestamp = os.time()
            self._is_first_message = false

            -- Re-render mode in chat header from preserved config_options
            local current_mode = self.config_options.mode
                    and self.config_options.mode.currentValue
                or self.config_options.legacy_agent_modes.current_mode_id
            if current_mode then
                self:_set_mode_to_chat_header(current_mode)
            end

            local finish_message = string.format(
                "\n### 🏁 Session restored - %s\n-----",
                os.date("%Y-%m-%d %H:%M:%S")
            )

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(finish_message)
            )
        end)
    end)
end

return SessionManager
