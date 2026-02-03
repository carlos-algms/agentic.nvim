local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text, not the buffer formatted content
--- @field timestamp integer Unix timestamp when message was sent
--- @field provider_name string

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field provider_name string
--- @field text string Agent response text (concatenated chunks)

--- @class agentic.ui.ChatHistory.ThoughtMessage : agentic.ui.ChatHistory.AgentMessage
--- @field type "thought"

--- @class agentic.ui.ChatHistory.ToolCall : agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id? string
--- @field type "tool_call"

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall

--- @class agentic.ui.ChatHistory.SessionMeta
--- @field session_id string
--- @field title string
--- @field timestamp integer

--- @class agentic.ui.ChatHistory.StorageData : agentic.ui.ChatHistory.SessionMeta
--- @field messages agentic.ui.ChatHistory.Message[]

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field timestamp integer Unix timestamp when session was created
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field title string
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- @return agentic.ui.ChatHistory
function ChatHistory:new()
    --- @type agentic.ui.ChatHistory
    local instance = {
        session_id = nil,
        timestamp = os.time(),
        messages = {},
        title = "",
    }

    setmetatable(instance, self)
    return instance
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

--- Get the folder path for storing sessions for the current project
--- @return string folder_path
function ChatHistory.get_sessions_folder()
    local base = Config.session_restore.storage_path
        or vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    local project_folder = ChatHistory.get_project_folder()
    return vim.fs.joinpath(base, project_folder)
end

--- Generate the full file path for this session's JSON file
--- @param session_id string
--- @return string file_path
function ChatHistory.get_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".json"
    )
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    table.insert(self.messages, msg)
end

--- Append text to the last agent or thought message, or create a new one
--- @param msg { type: "agent"|"thought", text: string, provider_name: string  }
function ChatHistory:append_agent_text(msg)
    local last = self.messages[#self.messages]
    if last and last.type == msg.type then
        last.text = last.text .. msg.text
    else
        table.insert(self.messages, msg)
    end
end

--- Update an existing tool_call by merging update data
--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
function ChatHistory:update_tool_call(tool_call_id, update)
    for i = #self.messages, 1, -1 do
        local msg = self.messages[i]
        if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
            self.messages[i] = vim.tbl_deep_extend("force", msg, update)
            return
        end
    end
end

--- Prepend restored messages to prompt in ACP Content format
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param prompt agentic.acp.Content[] The prompt array to prepend to
function ChatHistory.prepend_restored_messages(messages, prompt)
    for _, msg in ipairs(messages) do
        -- Convert stored messages to ACP Content format
        if msg.type == "user" then
            table.insert(prompt, { type = "text", text = "User: " .. msg.text })
        elseif msg.type == "agent" then
            table.insert(
                prompt,
                { type = "text", text = "Assistant: " .. msg.text }
            )
        elseif msg.type == "thought" then
            table.insert(prompt, {
                type = "text",
                text = "Assistant (thinking): " .. msg.text,
            })
        elseif msg.type == "tool_call" and msg.argument then
            local tool_text = string.format(
                "Tool call (%s): %s",
                msg.kind or "unknown",
                msg.argument
            )
            -- Include tool output if available
            if msg.body and #msg.body > 0 then
                tool_text = tool_text
                    .. "\nResult:\n"
                    .. table.concat(msg.body, "\n")
            end
            table.insert(prompt, { type = "text", text = tool_text })
        end
    end
end

--- @param callback fun(err: string|nil)|nil
function ChatHistory:save(callback)
    local path = ChatHistory.get_file_path(self.session_id)
    local dir = vim.fn.fnamemodify(path, ":h")

    local dir_ok, dir_err = FileSystem.mkdirp(dir)
    if not dir_ok then
        Logger.debug("Failed to create directory:", dir, dir_err)
        if callback then
            callback(
                "Failed to create directory: " .. (dir_err or "unknown error")
            )
        end
        return
    end

    --- @type agentic.ui.ChatHistory.StorageData
    local data = {
        session_id = self.session_id,
        title = self.title,
        timestamp = self.timestamp,
        messages = self.messages,
    }

    local encode_ok, json = pcall(vim.json.encode, data)
    if not encode_ok then
        Logger.debug("JSON encoding failed:", json)
        if callback then
            callback("JSON encoding error")
        end
        return
    end

    FileSystem.write_file(path, json, function(write_err)
        if callback then
            vim.schedule(function()
                callback(write_err)
            end)
        end
    end)
end

--- @param session_id string
--- @param callback fun(history: agentic.ui.ChatHistory|nil, err: string|nil)
function ChatHistory.load(session_id, callback)
    local path = ChatHistory.get_file_path(session_id)

    FileSystem.read_file(path, nil, nil, function(content)
        if not content then
            vim.schedule(function()
                callback(nil, "Failed to read file")
            end)
            return
        end

        local ok, parsed = pcall(vim.json.decode, content)
        if not ok then
            Logger.debug("JSON decode failed:", parsed)
            vim.schedule(function()
                callback(nil, "JSON decode error")
            end)
            return
        end

        --- @cast parsed agentic.ui.ChatHistory.StorageData

        local instance = ChatHistory:new()
        instance.session_id = parsed.session_id
        instance.timestamp = parsed.timestamp
        instance.messages = parsed.messages
        instance.title = parsed.title

        vim.schedule(function()
            callback(instance, nil)
        end)
    end)
end

--- List all sessions for the current project, sorted by timestamp descending
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_sessions(callback)
    local folder = ChatHistory.get_sessions_folder()
    local sessions = {}

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback(sessions)
        return
    end

    for filename, file_type in vim.fs.dir(folder) do
        if file_type == "file" and filename:match("%.json$") then
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

    table.sort(sessions, function(a, b)
        return a.timestamp > b.timestamp
    end)

    callback(sessions)
end

return ChatHistory
