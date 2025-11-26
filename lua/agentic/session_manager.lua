-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic._SessionManagerPrivate
local P = {}

--- @class agentic.SessionManager
--- @field session_id string|nil
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field current_provider string
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field slash_commands agentic.acp.SlashCommands
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
    local FileList = require("agentic.ui.file_list")
    local CodeSelection = require("agentic.ui.code_selection")

    local instance = setmetatable({
        session_id = nil,
        current_provider = Config.provider,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    instance.agent = agent

    instance.widget = ChatWidget:new(tab_page_id, function(input_text)
        --- @diagnostic disable-next-line: invisible
        instance:_handle_input_submit(input_text)
    end)

    instance.message_writer = MessageWriter:new(instance.widget.buf_nrs.chat)

    instance.status_animation =
        StatusAnimation:new(instance.widget.buf_nrs.chat)

    instance.permission_manager = PermissionManager:new(instance.message_writer)

    instance.slash_commands = SlashCommands:new(instance.widget.buf_nrs.input)

    instance.file_list = FileList:new(
        instance.widget.buf_nrs.files,
        function(file_list)
            if file_list:is_empty() then
                instance.widget:close_files_window()
                instance.widget:move_cursor_to(instance.widget.win_nrs.input)
            else
                instance.widget:render_header("files")
            end
        end
    )

    instance.code_selection = CodeSelection:new(
        instance.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                instance.widget:close_code_window()
                instance.widget:move_cursor_to(instance.widget.win_nrs.input)
            else
                instance.widget:render_header("code")
            end
        end
    )

    instance:new_session()

    return instance
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
    elseif update.sessionUpdate == "tool_call" then
        self.message_writer:write_tool_call_block(update)
    elseif update.sessionUpdate == "tool_call_update" then
        self.message_writer:update_tool_call_block(update)

        if update.status == "failed" then
            self.permission_manager:remove_request_by_tool_call_id(
                update.toolCallId
            )

            if
                not self.permission_manager.current_request
                and #self.permission_manager.queue == 0
            then
                self.status_animation:start("generating")
            end
        end
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
    local prompt = {
        {
            type = "text",
            text = input_text,
        },
    }

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

    self.agent:send_prompt(self.session_id, prompt, function(_response, err)
        vim.schedule(function()
            self.status_animation:stop()

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
        end)
    end)
end

--- Create a new session, cancelling any existing one and clearing buffers content
function SessionManager:new_session()
    self.widget:clear()
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

        on_read_file = function(...)
            P.on_read_file(...)
        end,

        on_write_file = function(...)
            P.on_write_file(...)
        end,

        on_session_update = function(update)
            self:_on_session_update(update)
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
        self.agent:cancel_session(self.session_id)
    end

    self.session_id = nil
    self.file_list:clear()
    self.code_selection:clear()

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

--- @param buf number|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- @type agentic.acp.ClientHandlers.on_read_file
function P.on_read_file(abs_path, line, limit, callback)
    local lines, err = FileSystem.read_from_buffer_or_disk(abs_path)
    lines = lines or {}

    if err ~= nil then
        vim.notify(
            "Agent file read error: " .. err,
            vim.log.levels.ERROR,
            { title = " Read file error" }
        )
        callback(nil)
        return
    end

    if line ~= nil and limit ~= nil then
        lines = vim.list_slice(lines, line, line + limit)
    end

    local content = table.concat(lines, "\n")
    callback(content)
end

--- @type agentic.acp.ClientHandlers.on_write_file
function P.on_write_file(abs_path, content, callback)
    local saved = FileSystem.save_to_disk(abs_path, content)

    if saved then
        local bufnr = vim.fn.bufnr(FileSystem.to_absolute_path(abs_path))

        if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(function()
                BufHelpers.execute_on_buffer(bufnr, function()
                    local view = vim.fn.winsaveview()
                    vim.cmd("checktime")
                    vim.fn.winrestview(view)
                end)
            end)
        end

        callback(nil)
        return
    end

    callback("Failed to write file: " .. abs_path)
end

function SessionManager:destroy()
    self:_cancel_session()
    self.widget:destroy()
end

return SessionManager
