local Logger = require("agentic.utils.logger")

--- Message types stored in chat history (raw data, not UI-formatted)

--- @class agentic.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text
--- @field timestamp? integer Unix timestamp when message was sent

--- @class agentic.ChatHistory.AgentMessage
--- @field type "agent"
--- @field text string Agent response text (concatenated chunks)

--- @class agentic.ChatHistory.ThoughtMessage
--- @field type "thought"
--- @field text string Agent thought text (concatenated chunks)

--- @class agentic.ChatHistory.ToolCall
--- @field type "tool_call"
--- @field tool_call_id string
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field argument? string
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff

--- @alias agentic.ChatHistory.Message
--- | agentic.ChatHistory.UserMessage
--- | agentic.ChatHistory.AgentMessage
--- | agentic.ChatHistory.ThoughtMessage
--- | agentic.ChatHistory.ToolCall

--- @class agentic.ChatHistory
--- @field session_id string
--- @field timestamp integer Unix timestamp when session was created
--- @field messages agentic.ChatHistory.Message[]
--- @field _dir_path? string Custom base directory path (default: stdpath("cache"))
--- @field _title_override? string Manual title override (takes precedence over first user message)
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- Creates a new ChatHistory instance
--- @param session_id string
--- @param dir_path? string|nil Custom base directory path
--- @return agentic.ChatHistory
function ChatHistory:new(session_id, dir_path)
    --- @type agentic.ChatHistory
    local instance = {
        session_id = session_id,
        timestamp = os.time(),
        messages = {},
        _dir_path = dir_path,
    }

    return setmetatable(instance, self)
end

--- Generate the project folder name from CWD
--- Normalizes path by replacing slashes, spaces, and colons with underscores
--- Appends first 8 chars of SHA256 hash for collision resistance
--- @return string folder_name
function ChatHistory:_get_project_folder()
    local cwd = vim.uv.cwd() or ""

    -- Normalize: replace slashes, spaces, and colons with underscores
    -- Also remove leading underscore if path started with /
    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")

    -- Strong hash for collision resistance (first 8 chars of SHA256)
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Generate the full file path for this session's JSON file
--- @return string file_path
function ChatHistory:_get_file_path()
    local base = self._dir_path or vim.fn.stdpath("cache")
    local project_folder = self:_get_project_folder()
    local folder = vim.fs.joinpath(base, "agentic", "sessions", project_folder)
    return vim.fs.joinpath(folder, self.session_id .. ".json")
end

--- Add a message to the history
--- @param msg agentic.ChatHistory.Message
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
        --- @type agentic.ChatHistory.AgentMessage | agentic.ChatHistory.ThoughtMessage
        local new_msg = { type = msg_type, text = text }
        table.insert(self.messages, new_msg)
    end
end

--- Update an existing tool_call by merging update data
--- @param tool_call_id string
--- @param update table Fields to merge into the tool_call
function ChatHistory:update_tool_call(tool_call_id, update)
    for i, msg in ipairs(self.messages) do
        if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
            self.messages[i] = vim.tbl_deep_extend("force", msg, update)
            return
        end
    end
end

--- Get all messages
--- @return agentic.ChatHistory.Message[]
function ChatHistory:get_messages()
    return self.messages
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

    -- Manual override takes precedence
    if self._title_override then
        text = self._title_override
    else
        -- Find first user message
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

--- Clear all messages
function ChatHistory:clear()
    self.messages = {}
end

--- Save history to disk asynchronously
--- @param callback? fun(err: string|nil)
function ChatHistory:save(callback)
    local path = self:_get_file_path()
    local dir = vim.fn.fnamemodify(path, ":h")

    Logger.debug(
        "Saving chat history to:",
        path,
        "session_id:",
        self.session_id
    )

    -- Step 1: Create directory (synchronous, recursive)
    vim.fn.mkdir(dir, "p")

    -- Step 2: Serialize JSON with pcall for safety
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

    -- Step 3: Write file async
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

--- Load history from disk asynchronously
--- @param session_id string
--- @param dir_path? string|nil Custom base directory path
--- @param callback fun(history: agentic.ChatHistory|nil, err: string|nil)
function ChatHistory.load(session_id, dir_path, callback)
    -- Create temp instance to get file path
    local temp = ChatHistory:new(session_id, dir_path)
    local path = temp:_get_file_path()

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

                -- Create instance with restored data
                local instance = ChatHistory:new(parsed.session_id, dir_path)
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
--- @param dir_path? string|nil Custom base directory path
--- @param callback fun(sessions: {session_id: string, title: string, timestamp: integer}[])
function ChatHistory.list_sessions(dir_path, callback)
    local temp = ChatHistory:new("temp", dir_path)
    local project_folder = temp:_get_project_folder()
    local base = dir_path or vim.fn.stdpath("cache")
    local folder = vim.fs.joinpath(base, "agentic", "sessions", project_folder)

    local sessions = {}

    -- Check if directory exists
    if vim.fn.isdirectory(folder) == 0 then
        callback(sessions)
        return
    end

    -- Iterate all json files
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
                end
            end
        end
    end

    callback(sessions)
end

return ChatHistory
