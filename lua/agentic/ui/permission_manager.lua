local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

-- Priority order for permission option kinds based on ACP tool-calls documentation
-- Lower number = higher priority (appears first)
-- Order from https://agentclientprotocol.com/protocol/tool-calls.md:
-- 1. allow_once - Allow this operation only this time
-- 2. allow_always - Allow this operation and remember the choice
-- 3. reject_once - Reject this operation only this time
-- 4. reject_always - Reject this operation and remember the choice
local PERMISSION_KIND_PRIORITY = {
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

--- @class agentic.ui.PermissionManager
--- @field message_writer agentic.ui.MessageWriter Reference to MessageWriter instance
--- @field queue table[] Queue of pending requests {toolCallId, request, callback}
--- @field current_request? agentic.ui.PermissionManager.PermissionRequest Currently displayed request with button positions
--- @field keymap_info table[] Keymap info for cleanup {mode, lhs}
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param message_writer agentic.ui.MessageWriter
--- @return agentic.ui.PermissionManager
function PermissionManager:new(message_writer)
    local instance = setmetatable({
        message_writer = message_writer,
        queue = {},
        current_request = nil,
        keymap_info = {},
    }, self)

    return instance
end

--- Add a new permission request to the queue to be processed sequentially
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        return
    end

    local toolCallId = request.toolCall.toolCallId
    table.insert(self.queue, { toolCallId, request, callback })

    if not self.current_request then
        self:_process_next()
    end
end

function PermissionManager:_process_next()
    if #self.queue == 0 then
        return
    end

    local item = table.remove(self.queue, 1)
    local toolCallId = item[1]
    local request = item[2]
    local callback = item[3]
    local sorted_options = self._sort_permission_options(request.options)

    local button_start_row, button_end_row, option_mapping =
        self.message_writer:display_permission_buttons(
            request.toolCall.toolCallId,
            sorted_options
        )

    ---@class agentic.ui.PermissionManager.PermissionRequest
    self.current_request = {
        toolCallId = toolCallId,
        request = request,
        callback = callback,
        button_start_row = button_start_row,
        button_end_row = button_end_row,
        option_mapping = option_mapping,
    }

    self:_setup_keymaps(option_mapping)
end

--- @param options agentic.acp.PermissionOption[]
--- @return agentic.acp.PermissionOption[]
function PermissionManager._sort_permission_options(options)
    local sorted = {}
    for _, option in ipairs(options) do
        table.insert(sorted, option)
    end

    table.sort(sorted, function(a, b)
        local priority_a = PERMISSION_KIND_PRIORITY[a.kind] or 999
        local priority_b = PERMISSION_KIND_PRIORITY[b.kind] or 999
        return priority_a < priority_b
    end)

    return sorted
end

--- Complete the current request and process next in queue
--- @param option_id? string
function PermissionManager:_complete_request(option_id)
    local current = self.current_request
    if not current then
        return
    end

    self.message_writer:remove_permission_buttons(
        current.button_start_row,
        current.button_end_row
    )

    self:_remove_keymaps()
    current.callback(option_id)

    self.current_request = nil
    self:_process_next()
end

--- Clear all displayed buttons and keymaps, cancel all pending requests
function PermissionManager:clear()
    if self.current_request then
        self.message_writer:remove_permission_buttons(
            self.current_request.button_start_row,
            self.current_request.button_end_row
        )
        self:_remove_keymaps()

        pcall(self.current_request.callback, nil)
        self.current_request = nil
    end

    for _, item in ipairs(self.queue) do
        local callback = item[3]
        pcall(callback, nil)
    end

    self.queue = {}
end

--- Remove permission request for a specific tool call ID (e.g., when tool call fails)
--- @param toolCallId string
function PermissionManager:remove_request_by_tool_call_id(toolCallId)
    self.queue = vim.tbl_filter(function(item)
        return item[1] ~= toolCallId
    end, self.queue)

    if
        self.current_request
        and self.current_request.toolCallId == toolCallId
    then
        self:_complete_request(nil)
    end
end

--- @param option_mapping table<integer, string> Mapping from number (1-N) to option_id
function PermissionManager:_setup_keymaps(option_mapping)
    self:_remove_keymaps()

    -- Add buffer-local key mappings for each option
    for number, option_id in pairs(option_mapping) do
        local lhs = tostring(number)
        local callback = function()
            self:_complete_request(option_id)
        end

        BufHelpers.keymap_set(self.message_writer.bufnr, "n", lhs, callback, {
            desc = "Select permission option " .. tostring(number),
        })

        table.insert(self.keymap_info, { mode = "n", lhs = lhs })
    end
end

function PermissionManager:_remove_keymaps()
    if not vim.api.nvim_buf_is_valid(self.message_writer.bufnr) then
        return
    end

    for _, info in ipairs(self.keymap_info) do
        pcall(
            vim.keymap.del,
            info.mode,
            info.lhs,
            { buffer = self.message_writer.bufnr }
        )
    end
    self.keymap_info = {}
end

return PermissionManager
