-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic._SessionManagerPrivate
local P = {}

--- Safely invoke a user-configured hook
--- @param hook_name "on_prompt_submit" | "on_response_complete"
--- @param data table
function P.invoke_hook(hook_name, data)
    local Config = require("agentic.config")
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
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field current_provider string
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field slash_commands agentic.acp.SlashCommands
--- @field agent_modes agentic.acp.AgentModes
local SessionManager = {}
SessionManager.__index = SessionManager

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local Config = require("agentic.config")
    local ChatWidget = require("agentic.ui.chat_widget")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local SlashCommands = require("agentic.acp.slash_commands")
    local AgentModes = require("agentic.acp.agent_modes")
    local FileList = require("agentic.ui.file_list")
    local CodeSelection = require("agentic.ui.code_selection")
    local FilePicker = require("agentic.ui.file_picker")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        current_provider = Config.provider,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            self:new_session()
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.permission_manager = PermissionManager:new(self.message_writer)
    self.slash_commands = SlashCommands:new(self.widget.buf_nrs.input)
    FilePicker.new(self.widget.buf_nrs.input)

    self.agent_modes = AgentModes:new(self.widget.buf_nrs, function(mode_id)
        self:_handle_mode_change(mode_id)
    end)

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_files_window()
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget.headers.files.suffix = tostring(#file_list:get_files())
            self.widget:render_header("files")
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_code_window()
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget.headers.code.suffix =
                    tostring(#code_selection:get_selections())
                self.widget:render_header("code")
            end
        end
    )

    return self
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
        -- FIXIT: implement plan handling
        Logger.debug("Implement plan handling")
    elseif update.sessionUpdate == "agent_message_chunk" then
        self.status_animation:start("generating")
        self.message_writer:write_message_chunk(update)
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self.status_animation:start("thinking")
        self.message_writer:write_message_chunk(update)
    elseif update.sessionUpdate == "available_commands_update" then
        self.slash_commands:setCommands(update.availableCommands)
        Logger.debug(
            string.format(
                "Updated %d slash commands for session %s",
                #self.slash_commands.commands,
                self.session_id or "unknown"
            )
        )
    else
        -- TODO: Move this to Logger when confidence is high
        vim.notify(
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
        vim.schedule(function()
            if err then
                vim.notify(
                    "Failed to change mode: " .. err.message,
                    vim.log.levels.ERROR
                )
            else
                self.agent_modes.current_mode_id = mode_id
                self:_set_mode_to_chat_header(mode_id)

                vim.notify(
                    "Mode changed to: " .. mode_id,
                    vim.log.levels.INFO,
                    {
                        title = "Agentic Mode changed",
                    }
                )
            end
        end)
    end)
end

--- @param mode_id string
function SessionManager:_set_mode_to_chat_header(mode_id)
    local mode = self.agent_modes:get_mode(mode_id)
    self.widget.headers.chat.suffix =
        string.format("Mode: %s", mode and mode.name or mode_id)

    self.widget:render_header("chat")
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    -- Intercept /new command to start new session locally, cancelling existing one
    -- Its necessary to avoid race conditions and make sure everything is cleaned properly,
    -- the Agent might not send an identifiable response that could be acted upon
    if input_text:match("^/new%s*") then
        self:new_session()
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

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
            table.insert(
                prompt,
                self.agent:create_resource_link_content(file_path)
            )

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

    self.message_writer:write_message(
        self.agent:generate_user_message(message_lines)
    )

    self.status_animation:start("thinking")

    P.invoke_hook("on_prompt_submit", {
        prompt = input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id

    self.agent:send_prompt(self.session_id, prompt, function(_response, err)
        vim.schedule(function()
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
            end

            self.message_writer:write_message(
                self.agent:generate_agent_message(finish_message)
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
end

--- Create a new session, cancelling any existing one and clearing buffers content
function SessionManager:new_session()
    self:_cancel_session()

    self.status_animation:start("busy")

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            Logger.debug("Agent error: ", err)

            self.message_writer:write_message(
                self.agent:generate_agent_message({
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
        end,

        on_tool_call_update = function(tool_call_update)
            self.message_writer:update_tool_call_block(tool_call_update)

            -- I need to remove the permission request if the tool call failed before user granted it
            -- It could happen for many reasons, like invalid parameters, tool not found, etc.
            -- Mostly comes from the Agent.
            if tool_call_update.status == "failed" then
                self.permission_manager:remove_request_by_tool_call_id(
                    tool_call_update.tool_call_id
                )

                if
                    not self.permission_manager.current_request
                    and #self.permission_manager.queue == 0
                then
                    self.status_animation:start("generating")
                end
            end
        end,

        on_request_permission = function(request, callback)
            self.status_animation:stop()

            local wrapped_callback = function(option_id)
                callback(option_id)

                if
                    not self.permission_manager.current_request
                    and #self.permission_manager.queue == 0
                then
                    self.status_animation:start("generating")
                end
            end

            -- FIXIT: I might have to generate a tool call block
            -- Codex ask for permission before sending the `edit` tool call
            self.permission_manager:add_request(request, wrapped_callback)
        end,
    }

    self.agent:create_session(handlers, function(response, err)
        self.status_animation:stop()

        if err or not response then
            vim.notify(
                "Failed to create session: " .. (err or "unknown error"),
                vim.log.levels.ERROR,
                { title = "Session creation error" }
            )

            self.session_id = nil
            return
        end

        self.session_id = response.sessionId

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
                    vim.notify(
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

        -- Reset first message flag for new session, so system info is added again for this session
        self._is_first_message = true

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        vim.schedule(function()
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            local provider_name = self.agent.provider_config.name
            local session_id = self.session_id or "unknown"
            local welcome_message = string.format(
                "# Agentic - %s - %s\n- %s\n--- --",
                provider_name,
                session_id,
                timestamp
            )

            self.message_writer:write_message(
                self.agent:generate_user_message(welcome_message)
            )
        end)
    end)
end

function SessionManager:_cancel_session()
    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.file_list:clear()
        self.code_selection:clear()
    end

    self.session_id = nil
    self.permission_manager:clear()
    self.slash_commands:setCommands({})
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

--- @param buf? number|string Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
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

return SessionManager
