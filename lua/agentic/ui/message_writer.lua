local ToolCallDiff = require("agentic.ui.tool_call_diff")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffPreview = require("agentic.ui.diff_preview")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DECORATIONS = vim.api.nvim_create_namespace("agentic_tool_decorations")
local NS_PERMISSION_BUTTONS =
    vim.api.nvim_create_namespace("agentic_permission_buttons")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")
local NS_THINKING = vim.api.nvim_create_namespace("agentic_thinking")

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean TODO: check if it's still necessary to replace all occurrences or the agents send multiple requests

--- @class agentic.ui.MessageWriter.ToolCallBlock
--- @field tool_call_id string
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field file_path? string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean
--- @field _scroll_scheduled boolean
--- @field _on_content_changed? fun()
--- @field _last_sender? "user"|"agent"
--- @field _provider_name? string
--- @field _is_restoring boolean
--- @field _thinking_extmark_id? integer
--- @field _thinking_start_line? integer
--- @field _thinking_end_line? integer
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- @param bufnr integer
--- @return agentic.ui.MessageWriter instance
function MessageWriter:new(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll = nil,
        _scroll_scheduled = false,
        _is_restoring = false,
    }, self)

    return instance
end

--- @param callback fun()|nil
function MessageWriter:set_on_content_changed(callback)
    self._on_content_changed = callback
end

--- @param name string
function MessageWriter:set_provider_name(name)
    self._provider_name = name
end

--- Resets sender tracking so the next message writes a fresh header
function MessageWriter:reset_sender_tracking()
    self._last_sender = nil
    self:_clear_thinking_state()
end

--- Clears thinking block tracking state.
--- Called when a non-thought write breaks the thinking flow.
function MessageWriter:_clear_thinking_state()
    self._thinking_extmark_id = nil
    self._thinking_start_line = nil
    self._thinking_end_line = nil
end

--- Writes a structural message (e.g. welcome banner) without triggering
--- a sender header. Resets sender tracking after so the next real message
--- gets its own header.
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_structural_message(update)
    local saved = self._last_sender
    self._last_sender = "user"
    self:write_message(update)
    self._last_sender = saved
end

function MessageWriter:_notify_content_changed()
    if self._on_content_changed then
        self._on_content_changed()
    end
end

--- Wraps BufHelpers.with_modifiable and fires _notify_content_changed after.
--- The callback may return false to suppress the notification (e.g. on early-return without edits).
--- with_modifiable returns false for invalid buffers, which also suppresses notification.
--- @param fn fun(bufnr: integer): boolean|nil
function MessageWriter:_with_modifiable_and_notify_change(fn)
    local result = BufHelpers.with_modifiable(self.bufnr, fn)
    if result ~= false then
        self:_notify_content_changed()
    end
end

--- @type table<string, "user"|"agent">
local SENDER_MAP = {
    user_message_chunk = "user",
    agent_message_chunk = "agent",
    agent_thought_chunk = "agent",
    tool_call = "agent",
}

--- Writes a sender header to the buffer if the sender changed
--- @param session_update_type string
--- @return boolean header_written
function MessageWriter:_maybe_write_sender_header(session_update_type)
    if session_update_type == "plan" then
        return false
    end

    local sender = SENDER_MAP[session_update_type] or "agent"

    if sender == self._last_sender then
        return false
    end

    self._last_sender = sender

    local icons = Config.chat_icons or {}
    local header = ""

    if sender == "user" then
        local icon = icons.user or ""
        header = string.format("## %s User", icon)

        if not self._is_restoring then
            header =
                string.format("%s - %s", header, os.date("%Y-%m-%d %H:%M:%S"))
        end
    else
        local icon = icons.agent or ""
        local name = self._provider_name or "unknown"
        header = string.format("### %s Agent - %s", icon, name)
    end

    self:_with_modifiable_and_notify_change(function()
        self:_append_lines({ "", header, "" })
    end)

    return true
end

--- Writes a message during session restore (suppresses timestamp in user header)
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_restoring_message(update)
    self._is_restoring = true
    self:write_message(update)
    self._is_restoring = false
end

--- Writes a full message to the chat buffer and appends a trailing blank line
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text

    if not text or text == "" then
        return
    end

    self:_clear_thinking_state()
    self:_auto_scroll(self.bufnr)
    self:_maybe_write_sender_header(update.sessionUpdate)

    local lines = vim.split(text, "\n", { plain = true })

    self:_with_modifiable_and_notify_change(function()
        self:_append_lines(lines)
        self:_append_lines({ "" })
    end)
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message_chunk(update)
    if
        not update.content
        or update.content.type ~= "text"
        or not update.content.text
        or update.content.text == ""
    then
        return
    end

    local text = update.content.text

    self:_auto_scroll(self.bufnr)

    local is_thought = update.sessionUpdate == "agent_thought_chunk"

    -- Clear thinking state when leaving a thinking block
    if not is_thought then
        self:_clear_thinking_state()
    end

    -- Prepend emoji on first thought chunk of a block
    if is_thought and not self._thinking_extmark_id then
        text = Config.message_icons.thinking .. " " .. text
    end

    local header_written = self:_maybe_write_sender_header(update.sessionUpdate)

    -- First thought chunk after non-thought output: start on a new line
    -- so the thinking extmark doesn't recolor existing agent output
    local thought_after_output = is_thought
        and not self._thinking_extmark_id
        and self._last_message_type
        and self._last_message_type ~= "agent_thought_chunk"

    if header_written or thought_after_output then
        -- The header's trailing blank line will be consumed by set_text below,
        -- so prepend a newline to preserve spacing after the header.
        -- Same for thought chunks that follow non-thought output.
        text = "\n" .. text
    elseif
        self._last_message_type == "agent_thought_chunk"
        and update.sessionUpdate == "agent_message_chunk"
    then
        -- Different message type, add newline before appending, to create visual separation
        -- only for thought -> message
        text = "\n\n" .. text
    end

    self._last_message_type = update.sessionUpdate

    self:_with_modifiable_and_notify_change(function(bufnr)
        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        -- Capture start line before writing for new thinking blocks
        local thinking_start = nil
        if is_thought and not self._thinking_extmark_id then
            thinking_start = last_line
        end

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        local lines_to_write = vim.split(text, "\n", { plain = true })

        local success, err = pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            last_line,
            start_col,
            last_line,
            start_col,
            lines_to_write
        )

        if not success then
            Logger.debug("Failed to set text in buffer", err, lines_to_write)
            return false
        end

        -- Thinking extmark management
        if is_thought then
            if thinking_start then
                -- First chunk: skip leading separator when a newline was
                -- prepended (header written, or thought after non-thought output)
                if header_written or thought_after_output then
                    thinking_start = thinking_start + 1
                end
                self._thinking_start_line = thinking_start
            end

            local new_end_line = vim.api.nvim_buf_line_count(bufnr) - 1
            self._thinking_end_line = new_end_line
            self._thinking_extmark_id = self:_set_thinking_extmark(
                self._thinking_start_line,
                new_end_line,
                self._thinking_extmark_id
            )
        end
    end)
end

--- @param lines string[]
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.debug("Failed to append lines to buffer", err, lines)
    end
end

--- @param bufnr integer
--- @return boolean should_scroll
function MessageWriter:_check_auto_scroll(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end
    local winid = wins[1]
    local threshold = Config.auto_scroll and Config.auto_scroll.threshold

    if threshold == nil or threshold <= 0 then
        return false
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local distance_from_bottom = total_lines - cursor_line

    return distance_from_bottom <= threshold
end

--- @param bufnr integer Buffer number to scroll
function MessageWriter:_auto_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = self:_check_auto_scroll(bufnr)
    end

    if self._scroll_scheduled then
        return
    end
    self._scroll_scheduled = true

    vim.schedule(function()
        self._scroll_scheduled = false

        if vim.api.nvim_buf_is_valid(bufnr) then
            if self._should_auto_scroll then
                local wins = vim.fn.win_findbuf(bufnr)
                if #wins > 0 then
                    vim.api.nvim_win_call(wins[1], function()
                        vim.cmd("normal! G0zb")
                    end)
                end
            end
        end

        self._should_auto_scroll = nil
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    self:_clear_thinking_state()
    self:_auto_scroll(self.bufnr)
    self:_maybe_write_sender_header("tool_call")

    self:_with_modifiable_and_notify_change(function(bufnr)
        local kind = tool_call_block.kind

        -- Always add a leading blank line for spacing the previous message chunk
        self:_append_lines({ "" })

        local start_row = vim.api.nvim_buf_line_count(bufnr)
        local lines, highlight_ranges =
            self:_prepare_block_lines(tool_call_block)

        self:_append_lines(lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1

        self:_apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind or "other",
            highlight_ranges
        )

        tool_call_block.decoration_extmark_ids =
            ExtmarkBlock.render_block(bufnr, NS_DECORATIONS, {
                header_line = start_row,
                body_start = start_row + 1,
                body_end = end_row - 1,
                footer_line = end_row,
                hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
            })

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        self:_apply_header_highlight(start_row, tool_call_block.status)
        self:_apply_status_footer(end_row, tool_call_block.status)

        self:_append_lines({ "", "" })
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.debug(
            "Tool call block not found, ID: ",
            tool_call_block.tool_call_id
        )

        return
    end

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.debug(
            "Extmark not found",
            { tool_call_id = tracker.tool_call_id }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.debug(
            "Could not determine end row of tool call block",
            { tool_call_id = tracker.tool_call_id, details = details }
        )
        return
    end

    self:_with_modifiable_and_notify_change(function(bufnr)
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content
        if already_has_diff then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.debug("Footer line index out of bounds", {
                    old_end_row = old_end_row,
                    line_count = vim.api.nvim_buf_line_count(bufnr),
                })
                return false
            end

            -- Re-write header line so updated kind/argument are visible
            local header = self:_build_header_line(tracker)
            vim.api.nvim_buf_set_lines(
                bufnr,
                start_row,
                start_row + 1,
                false,
                { header }
            )

            self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
            tracker.decoration_extmark_ids =
                self:_render_decorations(start_row, old_end_row)

            self:_clear_status_namespace(start_row, old_end_row)
            self:_apply_status_highlights_if_present(
                start_row,
                old_end_row,
                tracker.status
            )

            return false
        end

        self:_clear_decoration_extmarks(tracker.decoration_extmark_ids)
        self:_clear_status_namespace(start_row, old_end_row)

        local new_lines, highlight_ranges = self:_prepare_block_lines(tracker)

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

        self:_apply_block_highlights(
            bufnr,
            start_row,
            new_end_row,
            tracker.kind,
            highlight_ranges
        )

        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
            id = tracker.extmark_id,
            end_row = new_end_row,
            right_gravity = false,
        })

        tracker.decoration_extmark_ids =
            self:_render_decorations(start_row, new_end_row)

        self:_apply_status_highlights_if_present(
            start_row,
            new_end_row,
            tracker.status
        )
    end)
end

--- Build the header line string for a tool call block
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string header
function MessageWriter:_build_header_line(tool_call_block)
    local kind = tool_call_block.kind or "other"
    local argument = tool_call_block.argument or ""

    -- Sanitize argument to prevent newlines in the header line
    -- nvim_buf_set_lines doesn't accept array items with embedded newlines
    argument = argument:gsub("\n", "\\n")

    return string.format(" %s(%s) ", kind, argument)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local kind = tool_call_block.kind

    local lines = {
        self:_build_header_line(tool_call_block),
    }

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            table.insert(lines, string.format("Read %d lines", line_count))

            --- @type agentic.ui.MessageWriter.HighlightRange
            local range = {
                type = "comment",
                line_index = #lines - 1,
            }

            table.insert(highlight_ranges, range)
        end
    elseif tool_call_block.diff then
        local diff_path = tool_call_block.file_path or ""

        local diff_blocks = ToolCallDiff.extract_diff_blocks({
            path = diff_path,
            old_text = tool_call_block.diff.old,
            new_text = tool_call_block.diff.new,
            replace_all = tool_call_block.diff.all,
        })

        local lang = Theme.get_language_from_path(diff_path)

        -- Hack to avoid triple backtick conflicts in markdown files
        local has_fences = lang ~= "md" and lang ~= "markdown"
        if has_fences then
            table.insert(lines, "```" .. lang)
        end

        for _, block in ipairs(diff_blocks) do
            local old_count = #block.old_lines
            local new_count = #block.new_lines
            local is_new_file = old_count == 0
            local is_modification = old_count == new_count and old_count > 0

            if is_new_file then
                for _, new_line in ipairs(block.new_lines) do
                    local line_index = #lines
                    table.insert(lines, new_line)

                    --- @type agentic.ui.MessageWriter.HighlightRange
                    local range = {
                        line_index = line_index,
                        type = "new",
                        old_line = nil,
                        new_line = new_line,
                    }

                    table.insert(highlight_ranges, range)
                end
            else
                local filtered = ToolCallDiff.filter_unchanged_lines(
                    block.old_lines,
                    block.new_lines
                )

                -- Insert old lines (removed content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.old_line then
                        local line_index = #lines
                        table.insert(lines, pair.old_line)

                        --- @type agentic.ui.MessageWriter.HighlightRange
                        local range = {
                            line_index = line_index,
                            type = "old",
                            old_line = pair.old_line,
                            new_line = is_modification and pair.new_line or nil,
                        }

                        table.insert(highlight_ranges, range)
                    end
                end

                -- Insert new lines (added content)
                for _, pair in ipairs(filtered.pairs) do
                    if pair.new_line then
                        local line_index = #lines
                        table.insert(lines, pair.new_line)

                        if not is_modification then
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new",
                                old_line = nil,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        else
                            --- @type agentic.ui.MessageWriter.HighlightRange
                            local range = {
                                line_index = line_index,
                                type = "new_modification",
                                old_line = pair.old_line,
                                new_line = pair.new_line,
                            }

                            table.insert(highlight_ranges, range)
                        end
                    end
                end
            end
        end

        -- Close code fences, if not markdown, to avoid conflicts
        if has_fences then
            table.insert(lines, "```")
        end
    else
        if tool_call_block.body then
            vim.list_extend(lines, tool_call_block.body)
        end
    end

    table.insert(lines, "")

    return lines, highlight_ranges
end

--- Display permission request buttons at the end of the buffer
--- @param tool_call_id string
--- @param options agentic.acp.PermissionOption[]
--- @return integer button_start_row Start row of button block
--- @return integer button_end_row End row of button block
--- @return table<integer, string> option_mapping Mapping from number (1-N) to option_id
function MessageWriter:display_permission_buttons(tool_call_id, options)
    local option_mapping = {}

    local lines_to_append = {
        "### Waiting for your response: ",
        "",
    }

    local tracker = self.tool_call_blocks[tool_call_id]

    if tracker then
        -- Sanitize argument to prevent newlines in the permission request, neovim throws error
        local sanitized_argument = tracker.argument:gsub("\n", "\\n")

        -- Get buffer width and limit the display line
        local winid = vim.fn.bufwinid(self.bufnr)

        local buf_width = 80 -- default fallback width, in case buf is not visible
        if winid ~= -1 then
            buf_width = vim.api.nvim_win_get_width(winid)
        end

        local tool_line =
            string.format(" %s(%s)", tracker.kind, sanitized_argument)

        -- Truncate if longer than buffer width, leaving space for "...)"
        if #tool_line > buf_width then
            tool_line = tool_line:sub(1, buf_width - 4) .. "...)"
        end

        vim.list_extend(lines_to_append, {
            tool_line,
            "", -- Blank line prevents markdown inline markers from spanning to next content
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

    table.insert(lines_to_append, "--- ---")

    local hint_line_index =
        DiffPreview.add_navigation_hint(tracker, lines_to_append)

    table.insert(lines_to_append, "")

    -- Ensure exactly one empty separator line before the permission block.
    -- During reanchor, remove_permission_buttons leaves a trailing empty
    -- line — reuse it instead of adding another one.
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local last_line = vim.api.nvim_buf_get_lines(
        self.bufnr,
        line_count - 1,
        line_count,
        false
    )[1]

    if last_line == "" then
        -- Buffer already ends with an empty line (left by
        -- remove_permission_buttons during reanchor). Reuse it as
        -- separator — include it in the block range so it gets
        -- cleaned up, but don't add another one.
        line_count = line_count - 1
    else
        -- No trailing empty line — prepend one as separator
        table.insert(lines_to_append, 1, "")
    end

    -- The separator line shifts hint position by 1 in both cases:
    -- existing empty line included in block range, or prepended empty line.
    if hint_line_index then
        hint_line_index = hint_line_index + 1
    end

    local button_start_row = line_count

    self:_auto_scroll(self.bufnr)

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines_to_append)
    end)

    local button_end_row = vim.api.nvim_buf_line_count(self.bufnr) - 1

    if hint_line_index then
        DiffPreview.apply_hint_styling(
            self.bufnr,
            NS_PERMISSION_BUTTONS,
            button_start_row,
            hint_line_index
        )
    end

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

    return button_start_row, button_end_row, option_mapping
end

--- @param start_row integer Start row of button block
--- @param end_row integer End row of button block
function MessageWriter:remove_permission_buttons(start_row, end_row)
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
            {
                "", -- a leading as separator from previous content
            }
        )
    end)
end

--- Replay saved chat history messages into the buffer.
--- Uses write_restoring_message for user messages
--- (suppresses timestamp), write_message for agent/thought
--- messages, and write_tool_call_block for tool calls.
--- Temporarily swaps _provider_name per message so agent
--- headers show the correct provider from history.
--- @param messages agentic.ui.ChatHistory.Message[]
function MessageWriter:replay_history_messages(messages)
    local ACPPayloads = require("agentic.acp.acp_payloads")
    local current_provider = self._provider_name

    for _, msg in ipairs(messages) do
        -- Show correct provider name per message
        if msg.provider_name then
            self._provider_name = msg.provider_name
        end

        if msg.type == "user" then
            self:write_restoring_message(
                ACPPayloads.generate_user_message(msg.text)
            )
        elseif msg.type == "agent" then
            self:write_message(ACPPayloads.generate_agent_message(msg.text))
        elseif msg.type == "thought" then
            self:_maybe_write_sender_header("agent_thought_chunk")

            local text = Config.message_icons.thinking .. " " .. msg.text
            local lines = vim.split(text, "\n", { plain = true })
            local start_line

            self:_with_modifiable_and_notify_change(function(bufnr)
                start_line = vim.api.nvim_buf_line_count(bufnr)
                self:_append_lines(lines)
                self:_append_lines({ "" })
            end)

            if start_line then
                local end_line = start_line + #lines - 1
                self:_set_thinking_extmark(start_line, end_line)
            end
        elseif msg.type == "tool_call" then
            self:write_tool_call_block(msg)
        end
    end

    -- Restore current provider for new messages
    self._provider_name = current_provider
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
    elseif kind ~= "edit" and kind ~= "switch_mode" then
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

--- Sets or updates a thinking highlight extmark over the given line range.
--- @param start_line integer
--- @param end_line integer
--- @param id integer|nil
--- @return integer extmark_id
function MessageWriter:_set_thinking_extmark(start_line, end_line, id)
    local end_line_text = vim.api.nvim_buf_get_lines(
        self.bufnr,
        end_line,
        end_line + 1,
        false
    )[1] or ""

    return vim.api.nvim_buf_set_extmark(
        self.bufnr,
        NS_THINKING,
        start_line,
        0,
        {
            id = id,
            hl_group = Theme.HL_GROUPS.THINKING,
            end_row = end_line,
            end_col = #end_line_text,
            hl_eol = true,
        }
    )
end

--- @param ids integer[]|nil
function MessageWriter:_clear_decoration_extmarks(ids)
    if not ids then
        return
    end

    for _, id in ipairs(ids) do
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

return MessageWriter
