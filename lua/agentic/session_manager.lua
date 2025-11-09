-- The session manager class glue together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the eixsting session (if any) and initializing a new one.
-- Wheen the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local Logger = require("agentic.utils.logger")

---@class agentic._SessionManagerPrivate
local P = {}

---@class agentic.SessionManager
---@field widget agentic.ui.ChatWidget
---@field agent agentic.acp.ACPClient
---@field message_writer agentic.ui.MessageWriter
local SessionManager = {}

---@param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local Config = require("agentic.config")
    local ChatWidget = require("agentic.ui.chat_widget")

    local instance = setmetatable({
        message_writer = nil,
        session_id = nil,
        current_provider = Config.provider,
    }, self)
    self.__index = self

    -- FIXIT: this wont work, as there's only 1 agent instance per provider globally, so the handlers will be ignored
    -- I need to create some pub/sub mechanism to route the messages to the correct session manager based on session id
    local agent = AgentInstance.get_instance(Config.provider, {
        on_error = function(err)
            Logger.debug("Agent error: ", err)
            vim.notify(
                "Agent error: " .. err,
                vim.log.levels.ERROR,
                { title = "🐞 Agent Error" }
            )

            -- FIXIT: maybe write the error to the chat widget?
        end,

        on_read_file = function(...)
            P.on_read_file(...)
        end,

        on_write_file = function(...)
            P.on_write_file(...)
        end,

        on_session_update = function(update)
            P.on_session_update(instance, update)
        end,

        on_request_permission = function(request)
            -- FIXIT: Handle permission requests from the agent
        end,
    })

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    instance.agent = agent

    instance.widget = ChatWidget:new(tab_page_id, function(input_text)
        instance.agent:send_prompt(instance.session_id, {
            {
                type = "text",
                text = input_text,
            },
        }, function(_response, err)
            if err then
                vim.notify("Error submitting prompt: " .. vim.inspect(err))
                return
            end
        end)
    end)

    local MessageWriter = require("agentic.ui.message_writer")
    if instance.widget.panels.chat and instance.widget.panels.chat.bufnr then
        instance.message_writer =
            MessageWriter:new(instance.widget.panels.chat.bufnr)
    end

    agent:create_session(function(response, err)
        if err or not response then
            return
        end

        instance.session_id = response.sessionId
    end)

    return instance
end

---@param session agentic.SessionManager
---@param update agentic.acp.SessionUpdateMessage
function P.on_session_update(session, update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
    elseif update.sessionUpdate == "agent_message_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "user_message_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "agent_thought_chunk" then
        session.message_writer:write_message(update)
    elseif update.sessionUpdate == "tool_call" then
    elseif update.sessionUpdate == "tool_call_update" then
    elseif update.sessionUpdate == "available_commands_update" then
    else
        -- TODO: Move this to Logger when confidence is high
        vim.notify(
            "Unknown session update type: " .. tostring(update.sessionUpdate),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end
end

---@type agentic.acp.ClientHandlers.on_read_file
function P.on_read_file(abs_path, line, limit, callback)
    local lines, err = P._read_file_from_buf_or_disk(abs_path)
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
    local file = io.open(abs_path, "w")
    if file then
        file:write(content)
        file:close()

        local buffers = vim.tbl_filter(function(bufnr)
            return vim.api.nvim_buf_is_valid(bufnr)
                and vim.fn.fnamemodify(
                        vim.api.nvim_buf_get_name(bufnr),
                        ":p"
                    )
                    == abs_path
        end, vim.api.nvim_list_bufs())

        local bufnr = next(buffers)

        if bufnr then
            vim.api.nvim_buf_call(bufnr, function()
                local view = vim.fn.winsaveview()
                vim.cmd("checktime")
                vim.fn.winrestview(view)
            end)
        end

        callback(nil)
        return
    end

    callback("Failed to write file: " .. abs_path)
end

--- Read the file content from a buffer if loaded, to get unsaved changes, or from disk otherwise
---@param abs_path string
---@return string[]|nil lines
---@return string|nil error
function P._read_file_from_buf_or_disk(abs_path)
    local ok, bufnr = pcall(vim.fn.bufnr, abs_path)
    if ok then
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            return lines, nil
        end
    end

    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" then
        return {}, "Cannot read a directory as file: " .. abs_path
    end

    local file, open_err = io.open(abs_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        content = content:gsub("\r\n", "\n")
        return vim.split(content, "\n"), nil
    else
        return {}, open_err
    end
end

return SessionManager
