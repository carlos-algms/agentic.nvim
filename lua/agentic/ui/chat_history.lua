local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text, not the buffer formatted content
--- @field timestamp? integer Unix timestamp when message was sent

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field text string Agent response text (concatenated chunks)

--- @class agentic.ui.ChatHistory.ThoughtMessage
--- @field type "thought"
--- @field text string Agent thought text (concatenated chunks)

-- FIXIT: check if it's not duplicated, we already have a type for tool calls, maybe?
--- @class agentic.ui.ChatHistory.ToolCall
--- @field type "tool_call"
--- @field tool_call_id string
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field argument? string
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall

--- @class agentic.ui.ChatHistory.StorageData
--- @field session_id string
--- @field title string
--- @field timestamp integer
--- @field messages agentic.ui.ChatHistory.Message[]

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field timestamp integer Unix timestamp when session was created
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field _title_override? string Manual title override (takes precedence over first user message)
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- @return agentic.ui.ChatHistory
function ChatHistory:new()
    --- @type agentic.ui.ChatHistory
    local instance = {
        session_id = nil,
        timestamp = os.time(),
        messages = {},
    }

    return setmetatable(instance, self)
end

--- Generate the project folder name from CWD
--- Normalizes path by replacing slashes, spaces, and colons with underscores
--- Appends first 8 chars of SHA256 hash for collision resistance
function ChatHistory.get_project_folder()
    local cwd = vim.uv.cwd() or ""

    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Generate the full file path for this session's JSON file
--- @param session_id string
--- @return string file_path
function ChatHistory.get_file_path(session_id)
    local base = Config.session_restore.storage_path or vim.fn.stdpath("cache")
    local project_folder = ChatHistory.get_project_folder()
    local folder = vim.fs.joinpath(base, "agentic", "sessions", project_folder)
    return vim.fs.joinpath(folder, session_id .. ".json")
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    table.insert(self.messages, msg)
end

--- Append text to the last agent or thought message, or create a new one
--- @param msg_type "agent"|"thought"
--- @param text string
function ChatHistory:append_agent_text(msg_type, text)
    local last = self.messages[#self.messages]
    if last and last.type == msg_type then
        last.text = last.text .. text
    else
        --- @type agentic.ui.ChatHistory.AgentMessage | agentic.ui.ChatHistory.ThoughtMessage
        local new_msg = { type = msg_type, text = text }
        table.insert(self.messages, new_msg)
    end
end

--- Update an existing tool_call by merging update data
--- @param tool_call_id string
--- @param update table -- FIXIT: if we have a better type for tool calls, use it here instead of table
function ChatHistory:update_tool_call(tool_call_id, update)
    for i = #self.messages, 1, -1 do
        local msg = self.messages[i]
        if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
            self.messages[i] = vim.tbl_deep_extend("force", msg, update)
            return
        end
    end
end

--- Set a manual title override (takes precedence over first user message)
--- @param title string
function ChatHistory:set_title(title)
    self._title_override = title
end

--- Get the session title (manual override or first user message, truncated to 100 chars)
--- @return string title
function ChatHistory:get_title()
    --- @type string
    local text

    if self._title_override then
        text = self._title_override
    else
        for _, msg in ipairs(self.messages) do
            if msg.type == "user" and msg.text then
                text = msg.text
                break
            end
        end
    end

    if not text then
        return ""
    end

    if #text > 100 then
        return text:sub(1, 100)
    end

    return text
end

function ChatHistory:clear()
    self.messages = {}
end

--- @param callback fun(err: string|nil)|nil
function ChatHistory:save(callback)
    local path = ChatHistory.get_file_path(self.session_id)
    local dir = vim.fn.fnamemodify(path, ":h")

    vim.fn.mkdir(dir, "p")

    --- @type agentic.ui.ChatHistory.StorageData
    local data = {
        session_id = self.session_id,
        title = self:get_title(),
        timestamp = self.timestamp,
        messages = self.messages,
    }

    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        Logger.debug("JSON encoding failed:", json)
        if callback then
            callback("JSON encoding error")
        end
        return
    end

    -- FIXIT: replace this with FileSystem.write_file
    vim.uv.fs_open(path, "w", 420, function(err_open, fd) -- 420 = 0644
        if err_open then
            Logger.debug("Failed to open:", err_open)
            if callback then
                vim.schedule(function()
                    callback(err_open)
                end)
            end
            return
        end

        vim.uv.fs_write(fd, json, 0, function(err_write)
            vim.uv.fs_close(fd)
            if err_write then
                Logger.debug("Failed to write:", err_write)
            end
            if callback then
                vim.schedule(function()
                    callback(err_write)
                end)
            end
        end)
    end)
end

--- @param session_id string
--- @param callback fun(history: agentic.ui.ChatHistory|nil, err: string|nil)
function ChatHistory.load(session_id, callback)
    local path = ChatHistory.get_file_path(session_id)

    -- FIXIT: replace this with FileSystem.read_file
    vim.uv.fs_open(path, "r", 420, function(err_open, fd)
        if err_open then
            Logger.debug("Failed to open for read:", err_open)
            vim.schedule(function()
                callback(nil, err_open)
            end)
            return
        end

        vim.uv.fs_fstat(fd, function(err_stat, stat)
            if err_stat or not stat then
                vim.uv.fs_close(fd)
                vim.schedule(function()
                    callback(nil, err_stat or "Failed to stat file")
                end)
                return
            end

            vim.uv.fs_read(fd, stat.size, 0, function(err_read, data)
                vim.uv.fs_close(fd)

                if err_read then
                    Logger.debug("Failed to read:", err_read)
                    vim.schedule(function()
                        callback(nil, err_read)
                    end)
                    return
                end

                local ok, parsed = pcall(vim.json.decode, data)
                if not ok then
                    Logger.debug("JSON decode failed:", parsed)
                    vim.schedule(function()
                        callback(nil, "JSON decode error")
                    end)
                    return
                end

                local instance = ChatHistory:new()
                instance.session_id = parsed.session_id
                instance.timestamp = parsed.timestamp
                instance.messages = parsed.messages or {}

                vim.schedule(function()
                    callback(instance, nil)
                end)
            end)
        end)
    end)
end

--- List all sessions for the current project
--- @param callback fun(sessions: {session_id: string, title: string, timestamp: integer}[])
function ChatHistory.list_sessions(callback)
    local project_folder = ChatHistory.get_project_folder()
    local base = Config.session_restore.storage_path or vim.fn.stdpath("cache")
    local folder = vim.fs.joinpath(base, "agentic", "sessions", project_folder)

    local sessions = {}

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback(sessions)
        return
    end

    for filename, type in vim.fs.dir(folder) do
        if type == "file" and filename:match("%.json$") then
            local file_path = vim.fs.joinpath(folder, filename)
            local content = vim.fn.readfile(file_path)
            if #content > 0 then
                local ok, parsed =
                    pcall(vim.json.decode, table.concat(content, "\n"))
                if ok and parsed then
                    table.insert(sessions, {
                        session_id = filename:gsub("%.json$", ""),
                        title = parsed.title or "",
                        timestamp = parsed.timestamp or 0,
                    })
                else
                    Logger.debug(
                        "Failed to parse session file:",
                        file_path,
                        parsed
                    )
                end
            end
        end
    end

    callback(sessions)
end

return ChatHistory
