local Logger = require("agentic.utils.logger")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local BufHelpers = require("agentic.utils.buf_helpers")

---@class agentic.ui.MessageWriter.BlockTracker
---@field extmark_id integer Range extmark spanning the block
---@field decoration_extmark_ids integer[] IDs of decoration extmarks from ExtmarkBlock
---@field kind string Tool call kind (read, edit, etc.)
---@field title string Tool call title/command (stored for updates)
---@field status string Current status (pending, completed, etc.)

---@class agentic.ui.MessageWriter
---@field bufnr integer
---@field ns_id integer Namespace for range extmarks
---@field decorations_ns_id integer Namespace for decoration extmarks
---@field permission_buttons_ns_id integer Namespace for permission button extmarks
---@field tool_call_blocks table<string, agentic.ui.MessageWriter.BlockTracker> Map tool_call_id to extmark
---@field hl_group string
local MessageWriter = {}
MessageWriter.__index = MessageWriter

-- Priority order for permission option kinds based on ACP tool-calls documentation
-- Lower number = higher priority (appears first)
-- Order from https://agentclientprotocol.com/protocol/tool-calls.md:
-- 1. allow_once - Allow this operation only this time
-- 2. allow_always - Allow this operation and remember the choice
-- 3. reject_once - Reject this operation only this time
-- 4. reject_always - Reject this operation and remember the choice
local _PERMISSION_KIND_PRIORITY = {
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

local _PERMISSION_ICON = {
    allow_once = "",
    allow_always = "",
    reject_once = "󰅗",
    reject_always = "󰱝",
}

---@param bufnr integer
---@return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        hl_group = "Comment",
        ns_id = vim.api.nvim_create_namespace("agentic_tool_blocks"),
        decorations_ns_id = vim.api.nvim_create_namespace(
            "agentic_tool_decorations"
        ),
        permission_buttons_ns_id = vim.api.nvim_create_namespace(
            "agentic_permission_buttons"
        ),
        tool_call_blocks = {},
    }, self)

    return instance
end

---@param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local text = nil
    if
        update.content
        and update.content.type == "text"
        and update.content.text
    then
        text = update.content.text
    else
        -- For now, only handle text content
        Logger.debug(
            "MessageWriter: Skipping non-text content or missing content"
        )
        return
    end

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines)
        self:_append_lines({ "", "" })
    end)
end

---@param lines string[]
---@return nil
function MessageWriter:_append_lines(lines)
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)

    BufHelpers.execute_on_buffer(self.bufnr, function()
        vim.cmd("normal! G0")
    end)
end

---@param update agentic.acp.ToolCallMessage
function MessageWriter:write_tool_call_block(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        local kind = update.kind or "tool_call"
        local command = update.title or ""

        local start_row = vim.api.nvim_buf_line_count(bufnr)
        local lines = self:_prepare_block_lines(update, kind, command)
        self:_append_lines(lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

        local decoration_ids =
            ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = self.hl_group,
            })

        -- Create range extmark for tracking (omit end_col to default to end of line)
        local extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        -- Track externally (store kind and title for ToolCallUpdate which lacks them)
        self.tool_call_blocks[update.toolCallId] = {
            extmark_id = extmark_id,
            decoration_extmark_ids = decoration_ids,
            kind = kind,
            title = command,
            status = update.status,
        }

        self:_append_lines({ "", "" })
    end)
end

---@param update agentic.acp.ToolCallUpdate
function MessageWriter:update_tool_call_block(update)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    local tracker = self.tool_call_blocks[update.toolCallId]
    if not tracker then
        Logger.debug(
            "Tool call block not found",
            { tool_call_id = update.toolCallId }
        )

        return
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        self.ns_id,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.debug("Extmark not found", { tool_call_id = update.toolCallId })
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = update.toolCallId, details = details }
        )
        return
    end

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        for _, id in ipairs(tracker.decoration_extmark_ids) do
            pcall(
                vim.api.nvim_buf_del_extmark,
                bufnr,
                self.decorations_ns_id,
                id
            )
        end

        local new_lines =
            self:_prepare_block_lines(update, tracker.kind, tracker.title)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        -- Update range extmark in-place
        vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
            id = tracker.extmark_id, -- CRITICAL: reuse same ID
            end_row = new_end_row,
            right_gravity = false,
        })

        -- Re-apply visual decorations
        tracker.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = new_end_row - 1,
                footer_line = new_end_row,
                hl_group = self.hl_group,
            })

        tracker.status = update.status or tracker.status
    end)
end

---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@param kind? string Tool call kind (required for ToolCallUpdate)
---@param title? string Tool call title (required for ToolCallUpdate)
---@return string[] lines Array of lines to render
function MessageWriter:_prepare_block_lines(update, kind, title)
    local lines = {}

    kind = kind or update.kind or "tool_call"
    title = title or update.title or ""

    if kind == "fetch" and update.rawInput and update.rawInput.query then
        kind = "WebSearch"
    end

    local header_text = string.format("%s(%s)", kind, title)
    table.insert(lines, header_text)

    if update.content and #update.content > 0 then
        for _, content_item in ipairs(update.content) do
            if content_item.type == "content" and content_item.content then
                if content_item.content.type == "text" then
                    local text = content_item.content.text or ""
                    if text == "" then
                        table.insert(lines, "")
                    else
                        -- Split text by newlines, handling empty lines properly
                        local text_lines =
                            vim.split(text, "\n", { plain = true })
                        for _, line in ipairs(text_lines) do
                            table.insert(lines, line)
                        end
                    end
                elseif content_item.content.type == "resource" then
                    local resource_text = content_item.content.resource.text
                        or ""
                    for line in resource_text:gmatch("[^\n]+") do
                        table.insert(lines, line)
                    end
                end
            elseif content_item.type == "diff" then
                table.insert(
                    lines,
                    string.format("diff: %s", content_item.path)
                )
            end
        end
    end

    local footer_text = tostring(update.status or "")
    if footer_text ~= "" then
        table.insert(lines, footer_text)
    end

    return lines
end

---Display permission request buttons at the end of the buffer
---@param request agentic.acp.RequestPermission
---@return integer button_start_row Start row of button block
---@return integer button_end_row End row of button block
---@return table<integer, string> option_mapping Mapping from number (1-N) to option_id
function MessageWriter:display_permission_buttons(request)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return 0, 0, {}
    end

    if not request.toolCall or not request.options or #request.options == 0 then
        Logger.debug("MessageWriter: Invalid permission request")
        return 0, 0, {}
    end

    local option_mapping = {}
    local sorted_options = self._sort_permission_options(request.options)

    local lines_to_append = {
        string.format("### Waiting for your response:  "),
        "",
    }

    for i, option in ipairs(sorted_options) do
        table.insert(
            lines_to_append,
            string.format(
                "- [%d] %s %s",
                i,
                _PERMISSION_ICON[option.kind] or "",
                option.name
            )
        )
        option_mapping[i] = option.optionId
    end

    table.insert(lines_to_append, "------")
    table.insert(lines_to_append, "")

    local button_start_row = vim.api.nvim_buf_line_count(self.bufnr)

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines_to_append)
    end)

    local button_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    -- Create extmark to track button block
    vim.api.nvim_buf_set_extmark(
        self.bufnr,
        self.permission_buttons_ns_id,
        button_start_row,
        0,
        {
            end_row = button_end_row,
            right_gravity = false,
        }
    )

    return button_start_row, button_end_row, option_mapping
end

---@param options agentic.acp.PermissionOption[]
---@return agentic.acp.PermissionOption[]
function MessageWriter._sort_permission_options(options)
    local sorted = {}
    for _, option in ipairs(options) do
        table.insert(sorted, option)
    end

    table.sort(sorted, function(a, b)
        local priority_a = _PERMISSION_KIND_PRIORITY[a.kind] or 999
        local priority_b = _PERMISSION_KIND_PRIORITY[b.kind] or 999
        return priority_a < priority_b
    end)

    return sorted
end

---@param start_row integer Start row of button block
---@param end_row integer End row of button block
function MessageWriter:remove_permission_buttons(start_row, end_row)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.permission_buttons_ns_id,
        start_row,
        end_row + 1
    )

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        pcall(
            vim.api.nvim_buf_set_lines,
            bufnr,
            start_row,
            end_row + 1,
            false,
            {}
        )
    end)
end

function MessageWriter:clear()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, self.ns_id, 0, -1)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.decorations_ns_id,
        0,
        -1
    )
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.permission_buttons_ns_id,
        0,
        -1
    )
    self.tool_call_blocks = {}
end

return MessageWriter
