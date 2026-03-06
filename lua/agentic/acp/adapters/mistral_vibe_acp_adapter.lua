local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.MistralVibeACPAdapter : agentic.acp.ACPClient
local MistralVibeACPAdapter = setmetatable({}, { __index = ACPClient })
MistralVibeACPAdapter.__index = MistralVibeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.MistralVibeACPAdapter
function MistralVibeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, MistralVibeACPAdapter) --[[@as agentic.acp.MistralVibeACPAdapter]]

    return self
end

--- @param json_str string|nil
--- @return any decoded_json
function MistralVibeACPAdapter:_decode_json(json_str)
    local decode_ok, json = pcall(vim.json.decode, json_str or "{}")

    if not decode_ok then
        Logger.notify("Mistral JSON decoding failed: " .. vim.inspect(json))
        return {}
    end

    return json
end

--- @class agentic.acp.MistralVibeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? string

--- @alias agentic.acp.MistralVibeRawInputJson
--- | { file_path: string }
--- | { task: string, agent: string }

--- @param update agentic.acp.MistralVibeToolCallMessage
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function MistralVibeACPAdapter:__build_tool_call_message(update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind == "other" and "execute" or update.kind,
        status = update.status or "pending",
        argument = update.title,
        body = self:extract_content_body(update),
    }

    if update.kind == "edit" then
        local content = update.content and update.content[1]
        if content then
            if content.type == "diff" then
                message.diff = {
                    new = self:safe_split(content.newText),
                    old = self:safe_split(content.oldText),
                    all = false,
                }
                message.argument = FileSystem.to_smart_path(content.path)
            end
        end
    else
        local json = self:_decode_json(update.rawInput) --[[@as agentic.acp.MistralVibeRawInputJson]]

        if json.agent then
            message.kind = "SubAgent"
            message.argument =
                string.format("Agent %s: %s", json.agent or "", json.task or "")
            message.body = {
                update.title or "",
            }
        end
    end

    return message
end

--- @class agentic.acp.MistralVibeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawOutput? string a JSON string
--- @field kind? agentic.acp.ToolKind

--- @alias agentic.acp.MistralVibeRawOutputJson
--- | { stdout: string, stderr: string }
--- | { response: string, turns_used: number, completed: boolean }
--- | { matches: string, match_count: number, was_truncated: boolean }

--- @protected
--- @param update agentic.acp.MistralVibeToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function MistralVibeACPAdapter:__build_tool_call_update(update)
    local message = ACPClient.__build_tool_call_update(self, update)

    local json = self:_decode_json(update.rawOutput)

    --- @type string[]|nil
    local new_body

    if json.stdout then
        new_body = self:safe_split(json.stdout)
    elseif json.turns_used then
        new_body = self:safe_split(json.response)
    elseif json.matches then
        new_body = self:safe_split(json.matches)
    end

    if new_body and #new_body > 0 then
        vim.list_extend(new_body, { "", "---", "" })
        vim.list_extend(new_body, message.body or {})
        message.body = new_body
    end

    return message
end

return MistralVibeACPAdapter
