local ACPDiffHandler = require("agentic.acp.acp_diff_handler")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_PERMISSION_BUTTONS =
    vim.api.nvim_create_namespace("agentic_permission_buttons")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.BlockTracker
--- @field extmark_id integer Range extmark spanning the block
--- @field decoration_extmark_ids integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field kind string Tool call kind (read, edit, etc.)
--- @field argument string Tool call title/command (stored for updates)
--- @field status string Current status (pending, completed, etc.)
--- @field has_diff boolean Whether this block contains diff content

--- @class agentic.ui.MessageWriter.ChunkQueueItem
--- @field type "text_chunk"|"tool_call_block"|"tool_call_update"|"permission_buttons"
--- @field text? string Text content (for text_chunk)
--- @field message_type? string Message type (for text_chunk)
--- @field update? agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate Tool call data
--- @field permission_data? {tool_call_id: string, options: agentic.acp.PermissionOption[], callback: function} Permission button data

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.BlockTracker> Map tool_call_id to extmark
--- @field _chunk_queue agentic.ui.MessageWriter.ChunkQueueItem[] Queue of pending chunks to process
--- @field _is_processing_queue boolean Whether currently processing a chunk from queue
--- @field _is_streaming boolean Whether currently streaming a message
--- @field _stream_type string|nil Current message type (agent_message_chunk, agent_thought_chunk, user_message_chunk)
--- @field _stream_start_line integer|nil Start line of current stream (0-based, for future styling)
--- @field _stream_line integer|nil Current line index (0-based)
--- @field _stream_col integer|nil Current column position
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- @param bufnr integer
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _chunk_queue = {},
        _is_processing_queue = false,
        _is_streaming = false,
        _stream_type = nil,
        _stream_start_line = nil,
        _stream_line = nil,
        _stream_col = nil,
    }, self)

    return instance
end

--- @private
function MessageWriter:_process_next_chunk()
    if #self._chunk_queue == 0 then
        self._is_processing_queue = false
        return
    end

    self._is_processing_queue = true

    local item = table.remove(self._chunk_queue, 1)

    BufHelpers.with_modifiable(self.bufnr, function()
        if item.type == "text_chunk" then
            -- Append text to stream (starts new stream if needed)
            self:_append_to_stream(item.text, item.message_type)

            vim.defer_fn(function()
                BufHelpers.execute_on_buffer(self.bufnr, function()
                    vim.cmd("normal! G0")
                    vim.cmd("redraw!")
                end)
            end, 150)
        elseif item.type == "tool_call_block" then
            -- Finalize streaming before writing tool block
            if self._is_streaming then
                local end_line = self._stream_line + 1
                vim.api.nvim_buf_set_lines(
                    self.bufnr,
                    end_line,
                    end_line,
                    false,
                    { "", "" }
                )

                self._is_streaming = false
                self._stream_type = nil
                self._stream_start_line = nil
                self._stream_line = nil
                self._stream_col = nil
            end

            -- Write tool call block directly
            self:_write_tool_call_block_internal(item.update)
        elseif item.type == "tool_call_update" then
            -- Tool updates don't interfere with streaming
            self:_update_tool_call_block_internal(item.update)
        elseif item.type == "permission_buttons" then
            -- Finalize streaming before displaying buttons
            if self._is_streaming then
                local end_line = self._stream_line + 1
                vim.api.nvim_buf_set_lines(
                    self.bufnr,
                    end_line,
                    end_line,
                    false,
                    { "", "" }
                )

                self._is_streaming = false
                self._stream_type = nil
                self._stream_start_line = nil
                self._stream_line = nil
                self._stream_col = nil
            end

            -- Display permission buttons
            local result = self:_display_permission_buttons_internal(
                item.permission_data.tool_call_id,
                item.permission_data.options
            )

            -- Call callback with result
            if item.permission_data.callback then
                item.permission_data.callback(result)
            end
        end
    end)

    self:_process_next_chunk()
end

--- @private
--- @param message_type string Message type (agent_message_chunk, agent_thought_chunk, user_message_chunk)
function MessageWriter:_start_streaming(message_type)
    if self._is_streaming then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(self.bufnr)

    self._is_streaming = true
    self._stream_type = message_type
    self._stream_start_line = line_count
    self._stream_line = line_count
    self._stream_col = 0
end

--- @private
--- @param text string Text to append to stream
--- @param message_type string Message type for this chunk
function MessageWriter:_append_to_stream(text, message_type)
    if not self._is_streaming then
        self:_start_streaming(message_type)
    end

    local parts = vim.split(text, "\n", { plain = true, trimempty = false })

    if #parts == 1 then
        -- No newlines in chunk - use set_text to append only the new portion
        -- This avoids flickering by only updating the changed part of the line
        local end_col = self._stream_col or 0
        vim.api.nvim_buf_set_text(
            self.bufnr,
            self._stream_line,
            self._stream_col,
            self._stream_line,
            end_col,
            { text }
        )

        self._stream_col = self._stream_col + #text
    else
        -- Read current line fresh right before using it
        local current_line = vim.api.nvim_buf_get_lines(
            self.bufnr,
            self._stream_line,
            self._stream_line + 1,
            false
        )[1] or ""

        local remaining_on_line = current_line:sub(self._stream_col + 1)

        -- First part: append to current line
        local first_line = current_line:sub(1, self._stream_col) .. parts[1]

        -- Middle parts: become new lines
        local middle_parts = {}
        for i = 2, #parts - 1 do
            table.insert(middle_parts, parts[i])
        end

        -- Last part: starts new line (with remaining content from original line)
        local last_part = parts[#parts] .. remaining_on_line

        -- Build all lines to set
        local lines_to_set = { first_line }
        vim.list_extend(lines_to_set, middle_parts)
        table.insert(lines_to_set, last_part)

        -- Replace current line and insert rest
        vim.api.nvim_buf_set_lines(
            self.bufnr,
            self._stream_line,
            self._stream_line + 1,
            false,
            lines_to_set
        )

        -- Update position to end of last inserted line
        self._stream_line = self._stream_line + #lines_to_set - 1
        self._stream_col = #parts[#parts]
    end
end

--- Finalizes the current streaming message by adding empty lines
--- Should be called when a turn completes or message type changes
function MessageWriter:finalize_streaming()
    if not self._is_streaming then
        return
    end

    BufHelpers.with_modifiable(self.bufnr, function()
        local end_line = self._stream_line + 1
        vim.api.nvim_buf_set_lines(
            self.bufnr,
            end_line,
            end_line,
            false,
            { "", "" }
        )

        self._is_streaming = false
        self._stream_type = nil
        self._stream_start_line = nil
        self._stream_line = nil
        self._stream_col = nil
    end)
end

--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = nil

    if
        update.content
        and update.content.type == "text"
        and update.content.text
    then
        text = update.content.text
    else
        Logger.debug(
            "MessageWriter: Skipping non-text content or missing content"
        )
        return
    end

    if not text or text == "" then
        return
    end

    local message_type = update.sessionUpdate

    table.insert(self._chunk_queue, {
        type = "text_chunk",
        text = text,
        message_type = message_type,
    })

    if not self._is_processing_queue then
        self:_process_next_chunk()
    end
end

--- @param update agentic.acp.ToolCallMessage
function MessageWriter:write_tool_call_block(update)
    if
        (not update.content or #update.content == 0)
        and (not update.rawInput or vim.tbl_isempty(update.rawInput))
    then
        -- Skipping tool call with empty content and rawInput,
        -- The agent will send another one
        return
    end

    table.insert(self._chunk_queue, {
        type = "tool_call_block",
        update = update,
    })

    if not self._is_processing_queue then
        self:_process_next_chunk()
    end
end

--- @private
--- @param update agentic.acp.ToolCallMessage
function MessageWriter:_write_tool_call_block_internal(update)
    local bufnr = self.bufnr
    local kind = update.kind or "tool_call"
    local argument = ""

    if kind == "fetch" then
        if update.rawInput and update.rawInput.query then
            kind = "WebSearch"
        end

        argument = (update.rawInput and update.rawInput.query)
            or (update.rawInput and update.rawInput.url)
            or "unknown fetch"
    else
        local file_path = update.rawInput and update.rawInput.file_path

        if file_path and file_path ~= "" then
            argument = FileSystem.to_smart_path(file_path)
        else
            local command = update.rawInput and update.rawInput.command

            if command and command ~= "" then
                if type(command) == "table" then
                    command = table.concat(command, " ")
                end
                argument = command
            else
                argument = update.title or "unknown argument"
            end
        end
    end

    local start_row = vim.api.nvim_buf_line_count(bufnr)
    local lines, highlight_ranges =
        self:_prepare_block_lines(update, kind, argument)

    -- Append lines directly (we're already in with_modifiable context)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

    local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

    self:_apply_block_highlights(
        bufnr,
        start_row,
        end_row,
        kind,
        highlight_ranges
    )

    local decoration_ids = ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })

    local extmark_id =
        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
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

    self:_apply_header_highlight(start_row, update.status)
    self:_apply_status_footer(end_row, update.status)

    -- Apply empty lines after tool call block to guarantee separation
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "" })
end

--- @param update agentic.acp.ToolCallUpdate
function MessageWriter:update_tool_call_block(update)
    table.insert(self._chunk_queue, {
        type = "tool_call_update",
        update = update,
    })

    if not self._is_processing_queue then
        self:_process_next_chunk()
    end
end

--- @private
--- @param update agentic.acp.ToolCallUpdate
function MessageWriter:_update_tool_call_block_internal(update)
    local bufnr = self.bufnr
    local tracker = self.tool_call_blocks[update.toolCallId]

    if not tracker then
        Logger.debug(
            "Tool call block not found",
            { tool_call_id = update.toolCallId }
        )
        return
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        NS_TOOL_BLOCKS,
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

        self:_clear_decoration_extmarks(tracker)
        tracker.decoration_extmark_ids =
            self:_render_decorations(start_row, old_end_row)

        self:_clear_status_namespace(start_row, old_end_row)
        self:_apply_status_highlights_if_present(
            start_row,
            old_end_row,
            update.status
        )

        return
    end

    self:_clear_decoration_extmarks(tracker)
    self:_clear_status_namespace(start_row, old_end_row)

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
        NS_DIFF_HIGHLIGHTS,
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

    vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
        id = tracker.extmark_id,
        end_row = new_end_row,
        right_gravity = false,
    })

    tracker.decoration_extmark_ids =
        self:_render_decorations(start_row, new_end_row)

    tracker.status = update.status or tracker.status
    self:_apply_status_highlights_if_present(
        start_row,
        new_end_row,
        update.status
    )
end

--- @param update agentic.acp.ToolCallMessage | agentic.acp.ToolCallUpdate
--- @param kind string Tool call kind (required for ToolCallUpdate)
--- @param argument string Tool call title (required for ToolCallUpdate)
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(update, kind, argument)
    local lines = {}

    local header_text = string.format(" %s(%s) ", kind, argument)
    table.insert(lines, header_text)

    --- @type agentic.ui.MessageWriter.HighlightRange[]
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

            local lang = Theme.get_language_from_path(argument)

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

--- Display permission request buttons at the end of the buffer
--- @param options agentic.acp.PermissionOption[]
--- @param callback? function Optional callback to receive result {button_start_row, button_end_row, option_mapping}
function MessageWriter:display_permission_buttons(
    tool_call_id,
    options,
    callback
)
    table.insert(self._chunk_queue, {
        type = "permission_buttons",
        permission_data = {
            tool_call_id = tool_call_id,
            options = options,
            callback = callback,
        },
    })

    if not self._is_processing_queue then
        self:_process_next_chunk()
    end
end

--- @private
--- @param options agentic.acp.PermissionOption[]
--- @return {button_start_row: integer, button_end_row: integer, option_mapping: table<integer, string>}
function MessageWriter:_display_permission_buttons_internal(
    tool_call_id,
    options
)
    local option_mapping = {}

    local lines_to_append = {
        "### Waiting for your response:",
        "",
    }

    local tracker = self.tool_call_blocks[tool_call_id]

    if tracker then
        vim.list_extend(lines_to_append, {
            string.format(" %s(%s)", tracker.kind, tracker.argument),
            "",
        })
    end

    for i, option in ipairs(options) do
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

    table.insert(lines_to_append, "")
    table.insert(lines_to_append, "---")
    table.insert(lines_to_append, "")

    -- Read button_start_row fresh (we're already in with_modifiable from queue processor)
    local button_start_row = vim.api.nvim_buf_line_count(self.bufnr)

    -- Append lines directly
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines_to_append)

    local button_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    -- Create extmark to track button block
    vim.api.nvim_buf_set_extmark(
        self.bufnr,
        NS_PERMISSION_BUTTONS,
        button_start_row,
        0,
        {
            end_row = button_end_row,
            right_gravity = false,
        }
    )

    -- Scroll to bottom after displaying buttons
    vim.defer_fn(function()
        BufHelpers.execute_on_buffer(self.bufnr, function()
            vim.cmd("normal! G0")
            vim.cmd("redraw!")
        end)
    end, 150)

    return {
        button_start_row = button_start_row,
        button_end_row = button_end_row,
        option_mapping = option_mapping,
    }
end

--- @param start_row integer Start row of button block
--- @param end_row integer End row of button block
function MessageWriter:remove_permission_buttons(start_row, end_row)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        Logger.debug("MessageWriter: Buffer is no longer valid")
        return
    end

    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_PERMISSION_BUTTONS,
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

--- Apply highlights to block content (either diff highlights or Comment for non-edit blocks)
--- @param bufnr integer
--- @param start_row integer Header line number
--- @param end_row integer Footer line number
--- @param kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
function MessageWriter:_apply_block_highlights(
    bufnr,
    start_row,
    end_row,
    kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(start_row, highlight_ranges)
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
                    NS_DIFF_HIGHLIGHTS,
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

--- @param start_row integer
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[]
function MessageWriter:_apply_diff_highlights(start_row, highlight_ranges)
    if not highlight_ranges or #highlight_ranges == 0 then
        return
    end

    for _, hl_range in ipairs(highlight_ranges) do
        local buffer_line = start_row + hl_range.line_index

        if hl_range.type == "old" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "new" then
            DiffHighlighter.apply_diff_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                nil,
                hl_range.new_line
            )
        elseif hl_range.type == "new_modification" then
            DiffHighlighter.apply_new_line_word_highlights(
                self.bufnr,
                NS_DIFF_HIGHLIGHTS,
                buffer_line,
                hl_range.old_line,
                hl_range.new_line
            )
        elseif hl_range.type == "comment" then
            local line = vim.api.nvim_buf_get_lines(
                self.bufnr,
                buffer_line,
                buffer_line + 1,
                false
            )[1]

            if line then
                vim.api.nvim_buf_set_extmark(
                    self.bufnr,
                    NS_DIFF_HIGHLIGHTS,
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

--- @param header_line integer 0-indexed header line number
--- @param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_header_highlight(header_line, status)
    if not status or status == "" then
        return
    end

    local line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        header_line,
        header_line + 1,
        false
    )[1]
    if not line then
        return
    end

    local hl_group = Theme.get_status_hl_group(status)
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, header_line, 0, {
        end_col = #line,
        hl_group = hl_group,
    })
end

--- @param footer_line integer 0-indexed footer line number
--- @param status string Status value (pending, completed, etc.)
function MessageWriter:_apply_status_footer(footer_line, status)
    if
        not vim.api.nvim_buf_is_valid(self.bufnr)
        or not status
        or status == ""
    then
        return
    end

    local icons = Config.status_icons or {}

    local icon = icons[status] or ""
    local hl_group = Theme.get_status_hl_group(status)

    vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, footer_line, 0, {
        virt_text = {
            { string.format(" %s %s ", icon, status), hl_group },
        },
        virt_text_pos = "overlay",
    })
end

--- @param tracker agentic.ui.MessageWriter.BlockTracker
function MessageWriter:_clear_decoration_extmarks(tracker)
    for _, id in ipairs(tracker.decoration_extmark_ids) do
        pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS_DECORATIONS, id)
    end
end

--- @param start_row integer
--- @param end_row integer
--- @return integer[] decoration_extmark_ids
function MessageWriter:_render_decorations(start_row, end_row)
    return ExtmarkBlock.render_block(self.bufnr, NS_DECORATIONS, {
        header_line = start_row,
        body_start = start_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- @param start_row integer
--- @param end_row integer
function MessageWriter:_clear_status_namespace(start_row, end_row)
    pcall(
        vim.api.nvim_buf_clear_namespace,
        self.bufnr,
        NS_STATUS,
        start_row,
        end_row + 1
    )
end

--- @param start_row integer
--- @param end_row integer
--- @param status string|nil
function MessageWriter:_apply_status_highlights_if_present(
    start_row,
    end_row,
    status
)
    if status then
        self:_apply_header_highlight(start_row, status)
        self:_apply_status_footer(end_row, status)
    end
end

function MessageWriter:clear()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local namespaces_to_clean = {
        NS_TOOL_BLOCKS,
        NS_DECORATIONS,
        NS_PERMISSION_BUTTONS,
        NS_DIFF_HIGHLIGHTS,
        NS_STATUS,
    }

    for _, ns in ipairs(namespaces_to_clean) do
        pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, ns, 0, -1)
    end

    self.tool_call_blocks = {}
    self._chunk_queue = {}
    self._is_processing_queue = false
    self._is_streaming = false
    self._stream_type = nil
    self._stream_start_line = nil
    self._stream_line = nil
    self._stream_col = nil
end

return MessageWriter
