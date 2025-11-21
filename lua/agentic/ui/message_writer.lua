local Logger = require("agentic.utils.logger")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local BufHelpers = require("agentic.utils.buf_helpers")
local ACPDiffHandler = require("agentic.acp.acp_diff_handler")
local DiffFormatter = require("agentic.utils.diff_formatter")
local DiffHighlighter = require("agentic.utils.diff_highlighter")

---@class agentic.ui.MessageWriter.BlockTracker
---@field extmark_id integer Range extmark spanning the block
---@field decoration_extmark_ids integer[] IDs of decoration extmarks from ExtmarkBlock
---@field kind string Tool call kind (read, edit, etc.)
---@field title string Tool call title/command (stored for updates)
---@field status string Current status (pending, completed, etc.)
---@field has_diff boolean Whether this block contains diff content

---@class agentic.ui.MessageWriter
---@field bufnr integer
---@field ns_id integer Namespace for range extmarks
---@field decorations_ns_id integer Namespace for decoration extmarks
---@field permission_buttons_ns_id integer Namespace for permission button extmarks
---@field diff_highlights_ns_id integer Namespace for diff highlight extmarks
---@field status_ns_id integer Namespace for status footer extmarks
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
        diff_highlights_ns_id = vim.api.nvim_create_namespace(
            "agentic_diff_highlights"
        ),
        status_ns_id = vim.api.nvim_create_namespace("agentic_status_footer"),
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

    vim.defer_fn(function()
        BufHelpers.execute_on_buffer(self.bufnr, function()
            vim.cmd("normal! G0")
            vim.cmd("redraw!")
        end)
    end, 150)
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
        local lines, highlight_ranges =
            self:_prepare_block_lines(update, kind, command)
        self:_append_lines(lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                self:_apply_diff_highlights(bufnr, start_row, highlight_ranges)
            end
        end)

        local decoration_ids =
            ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = self.hl_group,
            })

        local extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        local has_diff = false
        for _, hl in ipairs(highlight_ranges) do
            if
                hl.type == "old"
                or hl.type == "new"
                or hl.type == "new_modification"
            then
                has_diff = true
                break
            end
        end
        self.tool_call_blocks[update.toolCallId] = {
            extmark_id = extmark_id,
            decoration_extmark_ids = decoration_ids,
            kind = kind,
            title = command,
            status = update.status,
            has_diff = has_diff,
        }

        if update.status then
            self:_apply_status_footer(bufnr, end_row, update.status)
        end

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
        if tracker.has_diff then
            if old_end_row >= vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return
            end

            tracker.status = update.status or tracker.status

            for _, id in ipairs(tracker.decoration_extmark_ids) do
                pcall(
                    vim.api.nvim_buf_del_extmark,
                    bufnr,
                    self.decorations_ns_id,
                    id
                )
            end

            tracker.decoration_extmark_ids =
                ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                    header_line = start_row,
                    body_start = start_row + 1,
                    body_end = old_end_row - 1,
                    footer_line = old_end_row,
                    hl_group = self.hl_group,
                })

            pcall(
                vim.api.nvim_buf_clear_namespace,
                bufnr,
                self.status_ns_id,
                old_end_row,
                old_end_row + 1
            )
            if update.status then
                self:_apply_status_footer(bufnr, old_end_row, update.status)
            end

            return
        end

        for _, id in ipairs(tracker.decoration_extmark_ids) do
            pcall(
                vim.api.nvim_buf_del_extmark,
                bufnr,
                self.decorations_ns_id,
                id
            )
        end

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            self.status_ns_id,
            old_end_row,
            old_end_row + 1
        )

        local new_lines, highlight_ranges =
            self:_prepare_block_lines(update, tracker.kind, tracker.title)
        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            self.diff_highlights_ns_id,
            start_row,
            old_end_row + 1
        )
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                self:_apply_diff_highlights(bufnr, start_row, highlight_ranges)
            end
        end)

        vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
        })

        tracker.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = new_end_row - 1,
                footer_line = new_end_row,
                hl_group = self.hl_group,
            })

        tracker.status = update.status or tracker.status

        if update.status then
            self:_apply_status_footer(bufnr, new_end_row, update.status)
        end
    end)
end

---Extract file path from tool call update
---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@return string|nil file_path
local function extract_file_path(update)
    if
        update.locations
        and #update.locations > 0
        and update.locations[1].path
    then
        return update.locations[1].path
    end
    if update.rawInput and update.rawInput.file_path then
        return update.rawInput.file_path
    end
    return nil
end

---Get language identifier from file path for markdown code fences
---@param file_path string
---@return string language
local function get_language_from_path(file_path)
    local ext = file_path:match("%.([^%.]+)$")
    if not ext then
        return ""
    end

    local lang_map = {
        lua = "lua",
        js = "javascript",
        ts = "typescript",
        jsx = "jsx",
        tsx = "tsx",
        py = "python",
        rb = "ruby",
        go = "go",
        rs = "rust",
        c = "c",
        cpp = "cpp",
        java = "java",
        kt = "kotlin",
        swift = "swift",
        md = "markdown",
        html = "html",
        css = "css",
        scss = "scss",
        json = "json",
        yaml = "yaml",
        yml = "yaml",
        toml = "toml",
        xml = "xml",
        sh = "bash",
        bash = "bash",
        zsh = "zsh",
    }
    return lang_map[ext] or ext
end

---Format status with icon and get highlight group
---@param status string
---@return string formatted_status, string hl_group
local function format_status(status)
    local Config = require("agentic.config")
    local icons = Config.status_icons or {}

    local status_config = {
        pending = {
            icon = icons.pending or "󰔛",
            hl = "AgenticStatusPending",
        },
        completed = {
            icon = icons.completed or "",
            hl = "AgenticStatusCompleted",
        },
        failed = { icon = icons.failed or "󰅙", hl = "AgenticStatusFailed" },
        rejected = {
            icon = icons.rejected or "󰅙",
            hl = "AgenticStatusRejected",
        },
    }

    local config = status_config[status] or { icon = "", hl = "Comment" }
    return string.format(" %s %s ", config.icon, status), config.hl
end

---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@param kind? string Tool call kind (required for ToolCallUpdate)
---@param title? string Tool call title (required for ToolCallUpdate)
---@return string[] lines Array of lines to render
---@return table[] highlight_ranges Array of {line_index, hl_group} for highlighting (relative to returned lines)
function MessageWriter:_prepare_block_lines(update, kind, title)
    local lines = {}

    kind = kind or update.kind or "tool_call"
    local file_path = extract_file_path(update)
    local display_text = file_path or title or update.title or ""

    if kind == "fetch" and update.rawInput and update.rawInput.query then
        kind = "WebSearch"
        display_text = update.rawInput.query
    end

    local header_text = string.format("%s %s", kind, display_text)
    table.insert(lines, header_text)
    local header_line_count = 1

    local highlight_ranges = {}

    if kind ~= "read" then
        local diff_items = {}
        for _, content_item in ipairs(update.content or {}) do
            if content_item.type == "diff" then
                table.insert(diff_items, content_item)
            end
        end

        if #diff_items > 0 then
            local diff_blocks = ACPDiffHandler.extract_diff_blocks({
                content = diff_items,
                rawInput = update.rawInput,
            })
            local formatted_lines, diff_highlights =
                DiffFormatter.format_diff_blocks(diff_blocks)

            local lang = file_path and get_language_from_path(file_path) or ""
            table.insert(lines, "```" .. lang)
            local fence_offset = #lines

            for _, hl in ipairs(diff_highlights) do
                hl.line_index = hl.line_index + fence_offset
            end
            vim.list_extend(highlight_ranges, diff_highlights)
            vim.list_extend(lines, formatted_lines)
            table.insert(lines, "```")
        end

        for _, content_item in ipairs(update.content) do
            if content_item.type == "content" and content_item.content then
                local content = content_item.content
                if content.type == "text" then
                    local text = content.text or ""
                    if text ~= "" then
                        vim.list_extend(
                            lines,
                            vim.split(text, "\n", { plain = true })
                        )
                    else
                        table.insert(lines, "")
                    end
                elseif content.type == "resource" then
                    for line in (content.resource.text or ""):gmatch("[^\n]+") do
                        table.insert(lines, line)
                    end
                end
            end
        end
    end

    if update.status and update.status ~= "" then
        table.insert(lines, "")
    end

    return lines, highlight_ranges
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

function MessageWriter:_apply_diff_highlights(
    bufnr,
    start_row,
    highlight_ranges
)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                self.diff_highlights_ns_id,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line,
                hl_range.is_modification or false
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                self.diff_highlights_ns_id,
                buffer_line,
                nil,
                hl_range.new_line,
                false
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                bufnr,
                self.diff_highlights_ns_id,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        end
    end
end

---Apply status footer virtual text
---@param bufnr integer
---@param footer_line integer 0-indexed footer line number
---@param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(bufnr, footer_line, status)
    if not vim.api.nvim_buf_is_valid(bufnr) or not status or status == "" then
        return
    end

    local formatted_text, hl_group = format_status(status)

    vim.api.nvim_buf_set_extmark(bufnr, self.status_ns_id, footer_line, 0, {
        virt_text = { { formatted_text, hl_group } },
        virt_text_pos = "overlay",
    })
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
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.diff_highlights_ns_id,
        0,
        -1
    )
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        self.status_ns_id,
        0,
        -1
    )
    self.tool_call_blocks = {}
end

return MessageWriter
