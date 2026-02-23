-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SessionRestore = require("agentic.session_restore")
local SlashCommands = require("agentic.acp.slash_commands")
local TodoList = require("agentic.ui.todo_list")

--- @class agentic._SessionManagerPrivate
local P = {}

--- Safely invoke a user-configured hook
--- @param hook_name "on_prompt_submit" | "on_response_complete"
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
--- @field _is_first_message boolean Whether this is the first message in the session, used to add system info only once
--- @field is_generating boolean
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field agent_modes agentic.acp.AgentModes
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field _history_to_send? agentic.ui.ChatHistory.Message[] Messages to prepend on next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
local SessionManager = {}
SessionManager.__index = SessionManager

--- Generate the welcome header for a new session
--- @param provider_name string
--- @param session_id string|nil
--- @return string header
function SessionManager._generate_welcome_header(provider_name, session_id)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    return string.format(
        "# Agentic - %s - %s\n- %s\n--- --",
        provider_name,
        session_id or "unknown",
        timestamp
    )
end

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local AgentModes = require("agentic.acp.agent_modes")
    local FileList = require("agentic.ui.file_list")
    local CodeSelection = require("agentic.ui.code_selection")
    local FilePicker = require("agentic.ui.file_picker")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            -- Skip auto-new_session if restore_from_history was called
            if not self._restoring then
                self:new_session()
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.permission_manager = PermissionManager:new(self.message_writer)

    FilePicker:new(self.widget.buf_nrs.input)
    SlashCommands.setup_completion(self.widget.buf_nrs.input)

    self.agent_modes = AgentModes:new(self.widget.buf_nrs, function(mode_id)
        self:_handle_mode_change(mode_id)
    end)

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

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
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
        if self.agent_modes:update_mode(update.currentModeId) then
            self:_set_mode_to_chat_header(update.currentModeId)
        end
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
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
function SessionManager:_handle_mode_change(mode_id)
    if not self.session_id then
        return
    end

    self.agent:set_mode(self.session_id, mode_id, function(_result, err)
        if err then
            Logger.notify(
                "Failed to change mode: " .. err.message,
                vim.log.levels.ERROR
            )
        else
            self.agent_modes.current_mode_id = mode_id
            self:_set_mode_to_chat_header(mode_id)

            Logger.notify("Mode changed to: " .. mode_id, vim.log.levels.INFO, {
                title = "Agentic Mode changed",
            })
        end
    end)
end

--- @param mode_id string
function SessionManager:_set_mode_to_chat_header(mode_id)
    local mode = self.agent_modes:get_mode(mode_id)
    self.widget:render_header(
        "chat",
        string.format("Mode: %s", mode and mode.name or mode_id)
    )
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    self.todo_list:close_if_all_completed()

    -- Intercept /new command to start new session locally, cancelling existing one
    -- Its necessary to avoid race conditions and make sure everything is cleaned properly,
    -- the Agent might not send an identifiable response that could be acted upon
    if input_text:match("^/new%s*") then
        self:new_session()
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- If restored/switched session, prepend history on first submit
    if self._history_to_send then
        self.chat_history.title = input_text -- Update title for restored session
        ChatHistory.prepend_restored_messages(self._history_to_send, prompt)
        self._history_to_send = nil
    elseif self.chat_history.title == "" then
        self.chat_history.title = input_text -- Set title for new session
    end

    -- Add system info on first message only
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = self:_get_system_info(),
        })
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    --- The message to be written to the chat widget
    local message_lines = {
        string.format("##  User - %s", os.date("%Y-%m-%d %H:%M:%S")),
    }

    table.insert(message_lines, "")
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

    table.insert(
        message_lines,
        "\n\n### 󱚠 Agent - " .. self.agent.provider_config.name
    )

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
    -- Capture chat_history before send to avoid race with _cancel_session
    -- replacing self.chat_history while the callback is pending
    local chat_history = self.chat_history

    self.is_generating = true

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        vim.schedule(function()
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

            -- Save chat history after successful turn completion
            if not err then
                chat_history:save(function(save_err)
                    if save_err then
                        Logger.debug("Chat history save error:", save_err)
                    end
                end)
            end
        end)
    end)
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        self:_cancel_session()
    end

    self.status_animation:start("busy")

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
            self.message_writer:write_tool_call_block(tool_call)
            -- Store full tool_call in chat history
            --- @type agentic.ui.ChatHistory.ToolCall
            local tool_msg = {
                type = "tool_call",
                tool_call_id = tool_call.tool_call_id,
                kind = tool_call.kind,
                status = tool_call.status,
                argument = tool_call.argument,
                body = tool_call.body,
                diff = tool_call.diff,
            }
            self.chat_history:add_message(tool_msg)
        end,

        on_tool_call_update = function(tool_call_update)
            self.message_writer:update_tool_call_block(tool_call_update)
            --- @type agentic.ui.ChatHistory.ToolCall
            local tool_call = {
                type = "tool_call",
                tool_call_id = tool_call_update.tool_call_id,
                status = tool_call_update.status,
                body = tool_call_update.body,
                diff = tool_call_update.diff,
            }

            self.chat_history:update_tool_call(
                tool_call_update.tool_call_id,
                tool_call
            )

            -- pre-emptively clear diff preview when tool call update is received, as it's either done or failed
            local is_rejection = tool_call_update.status == "failed"
            self:_clear_diff_in_buffer(
                tool_call_update.tool_call_id,
                is_rejection
            )

            -- I need to remove the permission request if the tool call failed before user granted it
            -- It could happen for many reasons, like invalid parameters, tool not found, etc.
            -- Mostly comes from the Agent.
            if tool_call_update.status == "failed" then
                self.permission_manager:remove_request_by_tool_call_id(
                    tool_call_update.tool_call_id
                )
            end

            if
                not self.permission_manager.current_request
                and #self.permission_manager.queue == 0
            then
                self.status_animation:start("generating")
            end
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

        if response.modes then
            self.agent_modes:set_modes(response.modes)

            local default_mode = self.agent.provider_config.default_mode
            local can_use_default = default_mode
                and default_mode ~= response.modes.currentModeId
                and self.agent_modes:get_mode(default_mode)

            if can_use_default and default_mode then
                self:_handle_mode_change(default_mode)
            else
                if
                    default_mode and not self.agent_modes:get_mode(default_mode)
                then
                    Logger.notify(
                        string.format(
                            "Configured default_mode '%s' not available. Using provider default.",
                            default_mode
                        ),
                        vim.log.levels.WARN,
                        { title = "Agentic" }
                    )
                end
                self:_set_mode_to_chat_header(response.modes.currentModeId)
            end
        end

        -- Reset first message flag for new session (skip when restoring)
        if not restore_mode then
            self._is_first_message = true
        end

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        -- For restore: write welcome first, then replay via on_created
        vim.schedule(function()
            local welcome_message = SessionManager._generate_welcome_header(
                self.agent.provider_config.name,
                self.session_id
            )

            self.message_writer:write_message(
                ACPPayloads.generate_user_message(welcome_message)
            )

            -- Invoke on_created callback after welcome message is written
            if on_created then
                on_created()
            end
        end)
    end)
end

function SessionManager:_cancel_session()
    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
    end

    self.session_id = nil
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})

    self.chat_history = ChatHistory:new()
    self._history_to_send = nil
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    -- Save references before get_instance (on_ready may fire synchronously)
    local saved_history = self.chat_history
    local old_agent = self.agent
    local old_session_id = self.session_id

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                self.agent = client

                self:new_session({
                    restore_mode = true,
                    on_created = function()
                        -- Capture new session metadata before overwriting
                        local new_session_id = self.chat_history.session_id
                        local new_timestamp = self.chat_history.timestamp

                        -- Restore saved messages (new_session created a fresh one)
                        self.chat_history = saved_history
                        self.chat_history.session_id = new_session_id
                        self.chat_history.timestamp = new_timestamp
                        self._history_to_send = saved_history.messages
                        self._is_first_message = true
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    -- Soft cancel: tear down old ACP session now that we have a new agent
    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    self.session_id = nil
    self.permission_manager:clear()
    self.todo_list:clear()

    -- If agent was already cached, on_ready fired synchronously above.
    -- If not, it will fire when the process is ready.
    self.agent = new_agent
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

--- @param buf number|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
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

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    DiffPreview.show_diff({
        file_path = tracker.argument,
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

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    DiffPreview.clear_diff(tracker.argument, is_rejection)
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

--- Restore session from loaded chat history
--- Creates a new ACP session (agent doesn't know old session_id)
--- and replays messages to UI. History is sent on first prompt submit.
--- @param history agentic.ui.ChatHistory
--- @param opts {reuse_session?: boolean}|nil If reuse_session=true, replay into current session without creating new one
function SessionManager:restore_from_history(history, opts)
    opts = opts or {}

    -- Prevent constructor's auto-new_session from running
    self._restoring = true
    self._history_to_send = history.messages
    self._is_first_message = false

    -- Update existing chat_history with loaded data, keeping current session_id
    if opts.reuse_session then
        self.chat_history.messages = vim.deepcopy(history.messages)
        self.chat_history.title = history.title or ""
    else
        self.chat_history = history
    end

    if opts.reuse_session and self.session_id then
        -- Reuse existing ACP session, just replay messages
        self._restoring = false
        SessionRestore.replay_messages(
            self.message_writer,
            self._history_to_send
        )
        -- ACP session already knows these messages; clear to prevent duplicate prepend
        self._history_to_send = nil
    else
        -- Create fresh ACP session, then replay messages after session is ready
        self:new_session({
            restore_mode = true,
            on_created = function()
                self._restoring = false
                SessionRestore.replay_messages(
                    self.message_writer,
                    self._history_to_send
                )
            end,
        })
    end
end

return SessionManager
