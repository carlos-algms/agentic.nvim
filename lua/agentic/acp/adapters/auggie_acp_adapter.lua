local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- Auggie-specific adapter that extends ACPClient with Auggie-specific behaviors
--- @class agentic.acp.AuggieACPAdapter : agentic.acp.ACPClient
local AuggieACPAdapter = setmetatable({}, { __index = ACPClient })
AuggieACPAdapter.__index = AuggieACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.AuggieACPAdapter
function AuggieACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, AuggieACPAdapter) --[[@as agentic.acp.AuggieACPAdapter]]

    return self
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function AuggieACPAdapter:__handle_tool_call(session_id, update)
    -- Skip empty tool calls
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        return
    end

    local kind = update.kind

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        local file_path = update.rawInput.file_path
        if file_path and file_path ~= "" then
            message.argument = FileSystem.to_smart_path(file_path)
        else
            message.argument = update.title or ""
        end

        if kind == "edit" then
            local new_string = update.rawInput.new_string
            local old_string = update.rawInput.old_string

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = update.rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if update.rawInput.query then
            -- Web search
            message.kind = "WebSearch"
            message.argument = update.rawInput.query
        elseif update.rawInput.url then
            -- URL fetch
            message.argument = update.rawInput.url
        else
            message.argument = "unknown fetch"
        end
    else
        -- Handle other tool types
        local command = update.rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or ""
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

return AuggieACPAdapter
