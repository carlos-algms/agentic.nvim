local ACPDiffHandler = require("agentic.acp.acp_diff_handler")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

---@class agentic.ui.MessageWriter.HighlightRange
---@field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
---@field line_index integer Line index relative to returned lines (0-based)
---@field old_line? string Original line content (for diff types)
---@field new_line? string Modified line content (for diff types)

---@class agentic.ui.MessageWriter.BlockTracker
---@field extmark_id integer Range extmark spanning the block
---@field decoration_extmark_ids integer[] IDs of decoration extmarks from ExtmarkBlock
---@field kind string Tool call kind (read, edit, etc.)
---@field argument string Tool call title/command (stored for updates)
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

---@param bufnr integer
---@return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
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
        local argument = ""

        if kind == "fetch" then
            if update.rawInput.query then
                kind = "WebSearch"
            end

            argument = update.rawInput.query
                or update.rawInput.url
                or "unknown fetch"
        else
            local file_path = self:_extract_file_path(update)
            local command = update.rawInput.command
            argument = file_path or command or update.title or ""
        end

        local start_row = vim.api.nvim_buf_line_count(bufnr)
        local lines, highlight_ranges =
            self:_prepare_block_lines(update, kind, argument)
        self:_append_lines(lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

        self:_apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind,
            highlight_ranges
        )

        local decoration_ids =
            ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
            })

        local extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[update.toolCallId] = {
            extmark_id = extmark_id,
            decoration_extmark_ids = decoration_ids,
            kind = kind,
            argument = argument,
            status = update.status,
            has_diff = ACPDiffHandler.has_diff_content(update),
        }

        self:_apply_header_highlight(bufnr, start_row, update.status)
        self:_apply_status_footer(bufnr, end_row, update.status)

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
        -- For blocks without diffs (read, fetch, etc.) or blocks with diffs,
        -- only update status highlights - don't replace content
        -- Exception: WebSearch and read need content updates when results arrive
        local needs_content_update = (
            tracker.kind == "WebSearch" or tracker.kind == "read"
        )
            and update.content
            and #update.content > 0

        if
            not needs_content_update
            and (tracker.has_diff or tracker.kind == "fetch")
        then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return
            end

            tracker.status = update.status or tracker.status

            self:_clear_decoration_extmarks(bufnr, tracker)
            tracker.decoration_extmark_ids =
                self:_render_decorations(bufnr, start_row, old_end_row)

            self:_clear_status_namespace(bufnr, start_row, old_end_row)
            self:_apply_status_highlights_if_present(
                bufnr,
                start_row,
                old_end_row,
                update.status
            )

            return
        end

        self:_clear_decoration_extmarks(bufnr, tracker)
        self:_clear_status_namespace(bufnr, start_row, old_end_row)

        local new_lines, highlight_ranges =
            self:_prepare_block_lines(update, tracker.kind, tracker.argument)
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
                self:_apply_block_highlights(
                    bufnr,
                    start_row,
                    new_end_row,
                    tracker.kind,
                    highlight_ranges
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
        })

        tracker.decoration_extmark_ids =
            self:_render_decorations(bufnr, start_row, new_end_row)

        tracker.status = update.status or tracker.status
        self:_apply_status_highlights_if_present(
            bufnr,
            start_row,
            new_end_row,
            update.status
        )
    end)
end

---Extract file path from tool call update
---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@return string|nil file_path
function MessageWriter:_extract_file_path(update)
    if update.rawInput.file_path then
        return FileSystem.to_smart_path(update.rawInput.file_path)
    end

    return nil
end

--- A lang map of extension to language identifier for markdown code fences
--- Keep only possible unknown mappings
local lang_map = {
    py = "python",
    rb = "ruby",
    rs = "rust",
    kt = "kotlin",
    htm = "html",
    yml = "yaml",
    sh = "bash",
}

---Get language identifier from file path for markdown code fences
---@param file_path string
---@return string language
local function get_language_from_path(file_path)
    local ext = vim.fn.fnamemodify(file_path, ":e")
    if not ext or ext == "" then
        return ""
    end

    return lang_map[ext] or ext
end

---@param status string
---@return string hl_group
local function get_status_hl_group(status)
    local status_hl = {
        pending = Theme.HL_GROUPS.STATUS_PENDING,
        completed = Theme.HL_GROUPS.STATUS_COMPLETED,
        failed = Theme.HL_GROUPS.STATUS_FAILED,
    }
    return status_hl[status] or "Comment"
end

---@param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
---@param kind string Tool call kind (required for ToolCallUpdate)
---@param argument string Tool call title (required for ToolCallUpdate)
---@return string[] lines Array of lines to render
---@return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(update, kind, argument)
    local lines = {}

    local header_text = string.format(" %s(%s) ", kind, argument)
    table.insert(lines, header_text)

    ---@type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = 0
        for _, content_item in ipairs(update.content or {}) do
            if content_item.type == "content" and content_item.content then
                local content = content_item.content
                if content.type == "text" and content.text then
                    local content_lines =
                        vim.split(content.text, "\n", { plain = true })
                    line_count = line_count + #content_lines
                end
            end
        end

        if line_count > 0 then
            local info_text = string.format("Read %d lines", line_count)
            table.insert(lines, info_text)

            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = {
                type = "comment",
                line_index = #lines - 1,
            }

            table.insert(highlight_ranges, range)
        end
    elseif kind == "fetch" or kind == "WebSearch" then
        -- Initial tool_call has rawInput with query/url
        if update.rawInput then
            if update.rawInput.prompt then
                table.insert(lines, update.rawInput.prompt)
            end
            if update.rawInput.url then
                table.insert(lines, update.rawInput.url)
            end
        end
    end

    if kind ~= "read" then
        if ACPDiffHandler.has_diff_content(update) then
            local diff_blocks = ACPDiffHandler.extract_diff_blocks(update)

            local lang = get_language_from_path(argument)

            -- Hack to avoid triple backtick conflicts in markdown files
            if lang ~= "md" then
                table.insert(lines, "```" .. lang)
            end

            -- Single-loop: format diff blocks and track highlights inline
            -- Sort file paths for deterministic ordering
            local sorted_paths = {}
            for path in pairs(diff_blocks) do
                table.insert(sorted_paths, path)
            end
            table.sort(sorted_paths)

            for _, path in ipairs(sorted_paths) do
                local blocks = diff_blocks[path]
                if blocks and #blocks > 0 then
                    for _, block in ipairs(blocks) do
                        local old_count = #block.old_lines
                        local new_count = #block.new_lines
                        local is_modification = old_count == new_count
                            and old_count > 0

                        -- Insert old lines (removed content)
                        for i, old_line in ipairs(block.old_lines) do
                            local line_index = #lines
                            table.insert(lines, old_line)

                            local new_line = is_modification
                                    and block.new_lines[i]
                                or nil

                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "old",
                                old_line = old_line,
                                new_line = new_line,
                            }

                            table.insert(highlight_ranges, range)
                        end

                        -- Insert new lines (added content)
                        for i, new_line in ipairs(block.new_lines) do
                            local line_index = #lines
                            table.insert(lines, new_line)

                            if not is_modification then
                                -- Pure addition
                                --- @type agentic.ui.MessageWriter.HighlightRange
                                local range = {
                                    line_index = line_index,
                                    type = "new",
                                    old_line = nil,
                                    new_line = new_line,
                                }

                                table.insert(highlight_ranges, range)
                            else
                                -- Modification with word-level diff
                                --- @type agentic.ui.MessageWriter.HighlightRange
                                local range = {
                                    line_index = line_index,
                                    type = "new_modification",
                                    old_line = block.old_lines[i],
                                    new_line = new_line,
                                }

                                table.insert(highlight_ranges, range)
                            end
                        end
                    end
                end
            end

            -- Close code fence if not markdown, to avoid conflicts
            if lang ~= "md" then
                table.insert(lines, "```")
            end
        end

        for _, content_item in ipairs(update.content or {}) do
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

    table.insert(lines, "")

    return lines, highlight_ranges
end

---Display permission request buttons at the end of the buffer
---@param request agentic.acp.RequestPermission
---@return integer button_start_row Start row of button block
---@return integer button_end_row End row of button block
---@return table<integer, string> option_mapping Mapping from number (1-N) to option_id
function MessageWriter:display_permission_buttons(request)
    if not request.toolCall or not request.options or #request.options == 0 then
        Logger.debug(
            "MessageWriter: Invalid permission request",
            vim.inspect(request)
        )
        return 0, 0, {}
    end

    local option_mapping = {}
    local sorted_options = self._sort_permission_options(request.options)

    local lines_to_append = {
        string.format("### Waiting for your response:  "),
        "",
    }

    local tracker = self.tool_call_blocks[request.toolCall.toolCallId]

    if tracker then
        vim.list_extend(lines_to_append, {
            string.format(" %s(%s)", tracker.kind, tracker.argument),
            "",
        })
    end

    for i, option in ipairs(sorted_options) do
        table.insert(
            lines_to_append,
            string.format(
                "%d. %s %s",
                i,
                Config.permission_icons[option.kind] or "",
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

---Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
---@param bufnr integer
---@param start_row integer Header line number
---@param end_row integer Footer line number
---@param kind string Tool call kind
---@param highlight_ranges table[] Diff highlight ranges
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(bufnr, start_row, highlight_ranges)
    elseif kind ~= "edit" then
        -- Apply Comment highlight for non-edit blocks without diffs
        for line_idx = start_row + 1, end_row - 1 do
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                line_idx,
                line_idx + 1,
                false
            )[1]
            if line and #line > 0 then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    self.diff_highlights_ns_id,
                    line_idx,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
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
                hl_range.new_line
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                self.diff_highlights_ns_id,
                buffer_line,
                nil,
                hl_range.new_line
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                bufnr,
                self.diff_highlights_ns_id,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    self.diff_highlights_ns_id,
                    buffer_line,
                    0,
                    {
                        end_col = #line,
                        hl_group = "Comment",
                    }
                )
            end
        end
    end
end

---@param bufnr integer
---@param header_line integer 0-indexed header line number
---@param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_header_highlight(bufnr, header_line, status)
    if not vim.api.nvim_buf_is_valid(bufnr) or not status or status == "" then
        return
    end

    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        header_line,
        header_line + 1,
        false
    )[1]
    if not line then
        return
    end

    local hl_group = get_status_hl_group(status)
    vim.api.nvim_buf_set_extmark(bufnr, self.status_ns_id, header_line, 0, {
        end_col = #line,
        hl_group = hl_group,
    })
end

---@param bufnr integer
---@param footer_line integer 0-indexed footer line number
---@param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(bufnr, footer_line, status)
    if not vim.api.nvim_buf_is_valid(bufnr) or not status or status == "" then
        return
    end

    local icons = Config.status_icons or {}

    local icon = icons[status] or ""
    local hl_group = get_status_hl_group(status)

    vim.api.nvim_buf_set_extmark(bufnr, self.status_ns_id, footer_line, 0, {
        virt_text = {
            { string.format(" %s %s ", icon, status), hl_group },
        },
        virt_text_pos = "overlay",
    })
end

---@param bufnr integer
---@param tracker agentic.ui.MessageWriter.BlockTracker
function MessageWriter:_clear_decoration_extmarks(bufnr, tracker)
    for _, id in ipairs(tracker.decoration_extmark_ids) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, self.decorations_ns_id, id)
    end
end

---@param bufnr integer
---@param start_row integer
---@param end_row integer
---@return integer[] decoration_extmark_ids
function MessageWriter:_render_decorations(bufnr, start_row, end_row)
    return ExtmarkBlock.render_block(bufnr, self.decorations_ns_id, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

---@param bufnr integer
---@param start_row integer
---@param end_row integer
function MessageWriter:_clear_status_namespace(bufnr, start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        bufnr,
        self.status_ns_id,
        start_row,
        end_row + 1
    )
end

---@param bufnr integer
---@param start_row integer
---@param end_row integer
---@param status string|nil
function MessageWriter:_apply_status_highlights_if_present(
    bufnr,
    start_row,
    end_row,
    status
)
    if status then
        self:_apply_header_highlight(bufnr, start_row, status)
        self:_apply_status_footer(bufnr, end_row, status)
    end
end

function MessageWriter:clear()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local namespaces_to_clean = {
        self.ns_id,
        self.decorations_ns_id,
        self.permission_buttons_ns_id,
        self.diff_highlights_ns_id,
        self.status_ns_id,
    }

    for _, ns in ipairs(namespaces_to_clean) do
        pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, ns, 0, -1)
    end
    self.tool_call_blocks = {}
end

return MessageWriter
