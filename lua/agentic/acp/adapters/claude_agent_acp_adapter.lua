local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.ClaudeAgentRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field subagent_type? string For sub-agent tasks (Task tool)
--- @field model? string Model used for sub-agent tasks
--- @field skill? string Skill name
--- @field args? string Arguments for the skill

--- claude-agent-acp sends rawInput/title/kind on tool_call_update, not just tool_call
--- @class agentic.acp.ClaudeAgentToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.ClaudeAgentRawInput
--- @field title? string
--- @field kind? agentic.acp.ToolKind

--- @class agentic.acp.ClaudeAgentACPAdapter : agentic.acp.ACPClient
local ClaudeAgentACPAdapter = setmetatable({}, { __index = ACPClient })
ClaudeAgentACPAdapter.__index = ClaudeAgentACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClaudeAgentACPAdapter
function ClaudeAgentACPAdapter:new(config, on_ready)
    self = ACPClient.new(ACPClient, config, on_ready)
    self = setmetatable(self, ClaudeAgentACPAdapter) --[[@as agentic.acp.ClaudeAgentACPAdapter]]
    return self
end

--- Build enriched update from rawInput fields that claude-agent-acp
--- sends on tool_call_update instead of tool_call.
--- @protected
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function ClaudeAgentACPAdapter:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
    }

    local rawInput = update.rawInput
    if not rawInput or vim.tbl_isempty(rawInput) then
        return message
    end

    local kind = update.kind

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(rawInput.file_path)

        if kind == "edit" then
            local new_string = rawInput.content or rawInput.new_string
            local old_string = rawInput.old_string

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if rawInput.query then
            message.kind = "WebSearch"
            message.argument = rawInput.query
        elseif rawInput.url then
            message.argument = rawInput.url

            if rawInput.prompt then
                message.argument =
                    string.format("%s %s", message.argument, rawInput.prompt)
            end
        else
            message.argument = "unknown fetch"
        end
    elseif kind == "think" and rawInput.subagent_type then
        message.kind = "SubAgent"
    elseif kind == "SubAgent" then
        message.argument = string.format(
            "%s, %s: %s",
            rawInput.model or "default",
            rawInput.subagent_type or "",
            rawInput.description or ""
        )

        if rawInput.prompt then
            message.body = self:safe_split(rawInput.prompt)
        end
    elseif kind == "other" then
        if update.title == "SlashCommand" then
            message.kind = "SlashCommand"
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = rawInput.skill or "unknown skill"

            if rawInput.args then
                message.body = self:safe_split(rawInput.args)
            end
        end
    else
        local command = rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or ""

        if not message.body then
            message.body = self:extract_content_body(update)
        end
    end

    return message
end

--- Claude-agent-acp sends tool call updates without status, so we need to overload to handle it
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call_update(session_id, update)
    if
        not update.status
        and (not update.rawInput or vim.tbl_isempty(update.rawInput))
    then
        return
    end

    local message = self:__build_tool_call_update(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return ClaudeAgentACPAdapter
