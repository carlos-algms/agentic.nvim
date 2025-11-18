-- The session manager class glue together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

---@class agentic._SessionManagerPrivate
local P = {}

---@class agentic.SessionManager
---@field session_id string|nil
---@field widget agentic.ui.ChatWidget
---@field agent agentic.acp.ACPClient
---@field message_writer agentic.ui.MessageWriter
---@field permission_manager agentic.ui.PermissionManager
---@field current_provider string
---@field selected_files string[]
---@field code_selections agentic.Selection[]
local SessionManager = {}

---@param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local Config = require("agentic.config")
    local ChatWidget = require("agentic.ui.chat_widget")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")

    local instance = setmetatable({
        session_id = nil,
        current_provider = Config.provider,
        selected_files = {},
        code_selections = {},
    }, self)
    self.__index = self

    local agent = AgentInstance.get_instance(Config.provider)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    instance.agent = agent

    instance.widget = ChatWidget:new(tab_page_id, function(input_text)
        ---@diagnostic disable-next-line: invisible
        instance:_handle_input_submit(input_text)
    end)

    instance.message_writer = MessageWriter:new(instance.widget.buf_nrs.chat)

    instance.permission_manager = PermissionManager:new(
        instance.widget.buf_nrs.chat,
        instance.message_writer
    )

    instance:_new_session()

    return instance
end

function SessionManager:_new_session()
    self:_cancel_session()
    ---@type agentic.acp.ClientHandlers
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
            self.permission_manager:add_request(request, callback)
        end,
    }

    self.agent:create_session(handlers, function(response, err)
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
            local provider_name = self.current_provider or "unknown"
            local session_id = self.session_id or "unknown"
            local welcome_message = string.format(
                "# Agentic - %s - %s\n- %s\n- ACP\n-----",
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
    if not self.session_id then
        return
    end

    self.agent:cancel_session(self.session_id)
    self.permission_manager:clear()
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self:get_selected_text()

    if selection then
        table.insert(self.code_selections, selection)
        self.widget:render_code_selection(self.code_selections)
        return true
    end

    return false
end

--- @param buf number|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    -- Check if file is already in selected_files
    for _, path in ipairs(self.selected_files) do
        if path == buf_path then
            return true
        end
    end

    local stat = vim.uv.fs_stat(buf_path)

    if stat and stat.type == "file" then
        table.insert(self.selected_files, buf_path)
        self.widget:render_selected_files(self.selected_files)
        return true
    end

    return false
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    --- The message to be sent to the agent
    --- @type agentic.acp.Content[]
    local prompt = {
        {
            type = "text",
            text = input_text,
        },
    }

    --- The message to be written to the chat widget
    local message_lines = {
        string.format("## User - %s", os.date("%Y-%m-%d %H:%M:%S")),
    }

    if #self.code_selections > 0 then
        table.insert(message_lines, "\n- Selected code:")

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

        for _, selection in ipairs(self.code_selections) do
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

        self.code_selections = {}
        table.insert(message_lines, "\n")
    end

    if #self.selected_files > 0 then
        table.insert(message_lines, "\n- Referenced files:")

        for _, file_path in ipairs(self.selected_files) do
            table.insert(
                prompt,
                self.agent:create_resource_link_content(file_path)
            )

            table.insert(
                message_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end

        self.selected_files = {}
        table.insert(message_lines, "\n")
    end

    table.insert(message_lines, input_text)

    table.insert(message_lines, "\n\n### Agent - " .. self.current_provider)

    self.message_writer:write_message(
        self.agent:generate_user_message(message_lines)
    )

    self.agent:send_prompt(self.session_id, prompt, function(_response, err)
        if err then
            vim.notify("Error submitting prompt: " .. vim.inspect(err))
            return
        end

        vim.schedule(function()
            local finish_message = string.format(
                "### 🏁 %s\n-----",
                os.date("%Y-%m-%d %H:%M:%S")
            )
            self.message_writer:write_message(
                self.agent:generate_agent_message(finish_message)
            )
        end)
    end)
end

---@param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
    elseif update.sessionUpdate == "agent_message_chunk" then
        self.message_writer:write_message(update)
    elseif update.sessionUpdate == "user_message_chunk" then
        self.message_writer:write_message(update)
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self.message_writer:write_message(update)
    elseif update.sessionUpdate == "tool_call" then
        self.message_writer:write_tool_call_block(update)
    elseif update.sessionUpdate == "tool_call_update" then
        self.message_writer:update_tool_call_block(update)

        if update.status == "failed" then
            self.permission_manager:remove_request_by_tool_call_id(
                update.toolCallId
            )
        end
    elseif update.sessionUpdate == "available_commands_update" then
    else
        -- TODO: Move this to Logger when confidence is high
        vim.notify(
            "Unknown session update type: "
                .. tostring(
                    ---@diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end
end

--- Get the current visual selection as text with start and end lines
--- @return agentic.Selection|nil
function SessionManager:get_selected_text()
    local mode = vim.fn.mode()

    if mode == "v" or mode == "V" or mode == "" then
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        local lines = vim.api.nvim_buf_get_lines(
            0,
            start_line - 1, -- 0-indexed
            end_line, -- exclusive
            false
        )

        -- exit visual mode to avoid issues with the input buffer
        local esc_key =
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
        vim.api.nvim_feedkeys(esc_key, "nx", false)

        ---@class agentic.Selection
        local selection = {
            lines = lines,
            start_line = start_line,
            end_line = end_line,
            file_path = FileSystem.to_smart_path(vim.api.nvim_buf_get_name(0)),
            file_type = vim.bo[0].filetype,
        }

        return selection
    end
end

---@type agentic.acp.ClientHandlers.on_read_file
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

---@type agentic.acp.ClientHandlers.on_write_file
function P.on_write_file(abs_path, content, callback)
    local saved = FileSystem.save_to_disk(abs_path, content)

    if saved then
        local bufnr = vim.fn.bufnr(FileSystem.to_absolute_path(abs_path))

        if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(function()
                vim.api.nvim_buf_call(bufnr, function()
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
