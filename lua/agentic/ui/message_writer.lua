local ToolCallDiff = require("agentic.ui.tool_call_diff")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local Fold = require("agentic.ui.tool_call_fold")
local JsonFormat = require("agentic.utils.json_format")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")
local NS_DIFF_HIGHLIGHTS =
    vim.api.nvim_create_namespace("agentic_diff_highlights")
local NS_STATUS = vim.api.nvim_create_namespace("agentic_status_footer")
local NS_THINKING = vim.api.nvim_create_namespace("agentic_thinking")

-- Static label map keyed by PermissionOptionKind
-- Agent-supplied option.name is intentionally discarded
local PERMISSION_OPTION_LABELS = {
    allow_once = "Allow",
    allow_always = "Allow Always",
    reject_once = "Reject",
    reject_always = "Reject Always",
}

local TITLE_FENCE = "`````"

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean TODO: check if it's still necessary to replace all occurrences or the agents send multiple requests

--- @class agentic.ui.MessageWriter.PermissionState
--- @field sorted_options agentic.acp.PermissionOption[] Options sorted by priority
--- @field is_focused boolean Whether the block is the currently focused permission target
--- @field focused_button_index? integer 1-indexed; which button inside the focused block is highlighted (h / l selection). Nil = no button focus (block not focused).

--- @class agentic.ui.MessageWriter.ToolCallBlock
--- @field tool_call_id string
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field file_path? string
--- @field extmark_id? integer Range extmark spanning the block
--- @field status? agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field has_fold? boolean
--- @field permission? agentic.ui.MessageWriter.PermissionState

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean
--- @field _scroll_scheduled boolean
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

    self = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll = nil,
        _scroll_scheduled = false,
        _is_restoring = false,
    }, self)

    return self
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

    BufHelpers.with_modifiable(self.bufnr, function()
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
    self:_capture_scroll(self.bufnr)
    self:_maybe_write_sender_header(update.sessionUpdate)

    local lines = vim.split(text, "\n", { plain = true })

    BufHelpers.with_modifiable(self.bufnr, function()
        self:_append_lines(lines)
        self:_append_lines({ "" })
    end)

    self:_apply_scroll(self.bufnr)
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

    self:_capture_scroll(self.bufnr)

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

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
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

    self:_apply_scroll(self.bufnr)
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

--- @param cursor_line integer 1-indexed window cursor row
--- @return boolean
function MessageWriter:_cursor_on_permission_button_row(cursor_line)
    local row = cursor_line - 1
    local marks = vim.api.nvim_buf_get_extmarks(
        self.bufnr,
        NS_STATUS,
        { row, 0 },
        { row + 1, 0 },
        { details = true, hl_name = true }
    )

    for _, mark in ipairs(marks) do
        local details = mark[4]
        local hl_group = details and details.hl_group

        if
            hl_group == Theme.HL_GROUPS.PERMISSION_BUTTON_INACTIVE
            or hl_group == Theme.HL_GROUPS.PERMISSION_BUTTON_ALLOW
            or hl_group == Theme.HL_GROUPS.PERMISSION_BUTTON_REJECT
        then
            return true
        end
    end

    return false
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

    if self:_cursor_on_permission_button_row(cursor_line) then
        return false
    end

    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local distance_from_bottom = total_lines - cursor_line

    return distance_from_bottom <= threshold
end

--- @param bufnr integer
function MessageWriter:_capture_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = self:_check_auto_scroll(bufnr)
    end
end

--- @param bufnr integer
function MessageWriter:_apply_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = nil
        return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        self._should_auto_scroll = nil
        return
    end

    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        self._should_auto_scroll = nil
        return
    end
    local winid = wins[1]

    vim.api.nvim_win_call(winid, function()
        vim.cmd("noautocmd normal! G0zb")
    end)

    self._should_auto_scroll = nil
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    if tool_call_block.body then
        tool_call_block.body = JsonFormat.format_lines(tool_call_block.body)
    end

    self:_clear_thinking_state()
    self:_capture_scroll(self.bufnr)
    self:_maybe_write_sender_header("tool_call")

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
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

        tool_call_block.extmark_id =
            vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, start_row, 0, {
                id = tool_call_block.extmark_id,
                end_row = end_row,
                right_gravity = false,
            })

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        self:_apply_header_highlight(start_row, tool_call_block.status)
        self:repaint_status_row(tool_call_block.tool_call_id)

        local body_start = start_row + 2
        local body_end = end_row - 2
        if
            Fold.should_fold({
                bufnr = bufnr,
                start_row = body_start,
                end_row = body_end,
                status = tool_call_block.status,
                is_diff = tool_call_block.diff ~= nil,
            })
        then
            Fold.close_range(bufnr, start_row + 2, end_row)
            tool_call_block.has_fold = true
        end

        self:_append_lines({ "", "" })
    end)

    self:_apply_scroll(self.bufnr)
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

    if tool_call_block.body then
        tool_call_block.body = JsonFormat.format_lines(tool_call_block.body)
    end

    self:_capture_scroll(self.bufnr)

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

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            start_row + 1,
            false,
            { self:_build_header_line(tracker) }
        )

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

            self:_clear_status_namespace(start_row, old_end_row)
            self:_apply_status_highlights_if_present(tracker)

            return false
        end

        self:_clear_status_namespace(start_row, old_end_row)

        local new_lines, highlight_ranges = self:_prepare_block_lines(tracker)

        local body_lines = vim.list_slice(new_lines, 3, #new_lines - 2)
        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row + 2,
            old_end_row - 1,
            false,
            body_lines
        )

        local new_end_row = start_row + #new_lines - 1

        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            NS_DIFF_HIGHLIGHTS,
            start_row,
            new_end_row + 1
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

        self:_apply_status_highlights_if_present(tracker)

        if
            not tracker.has_fold
            and Fold.should_fold({
                bufnr = bufnr,
                start_row = start_row + 2,
                end_row = new_end_row - 2,
                status = tracker.status,
                is_diff = tracker.diff ~= nil,
            })
        then
            Fold.close_range(bufnr, start_row + 2, new_end_row)
            tracker.has_fold = true
        end
    end)

    self:_apply_scroll(self.bufnr)
end

--- Build the header line string for a tool call block
--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string header
function MessageWriter:_build_header_line(tool_call_block)
    local kind = tool_call_block.kind or "other"
    local argument = self:_build_header_argument(tool_call_block)

    return string.format(" %s(%s) ", kind, argument)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string argument
function MessageWriter:_build_header_argument(tool_call_block)
    local argument = tool_call_block.argument or ""

    -- Sanitize argument to prevent newlines in the header line
    -- nvim_buf_set_lines doesn't accept array items with embedded newlines
    argument = argument:gsub("\n", "\\n")

    local max_length = self:_get_title_max_length()
    if
        max_length > 0
        and #argument > max_length
        and self:_should_render_full_title_body(tool_call_block)
    then
        return argument:sub(1, max_length) .. "..."
    end

    return argument
end

--- @return integer max_length
function MessageWriter:_get_title_max_length()
    local cfg = Config.tool_calls and Config.tool_calls.title
    local max_length = cfg and cfg.max_length

    if type(max_length) ~= "number" or max_length < 0 then
        return 0
    end

    return max_length
end

--- @param kind string|nil
--- @return boolean enabled
function MessageWriter:_title_kind_enabled(kind)
    if not kind then
        return false
    end

    local cfg = Config.tool_calls and Config.tool_calls.title
    local kinds = cfg and cfg.truncate_title_kinds

    if type(kinds) ~= "table" then
        return false
    end

    for _, configured_kind in ipairs(kinds) do
        if configured_kind == kind then
            return true
        end
    end

    return false
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return boolean should_render
function MessageWriter:_should_render_full_title_body(tool_call_block)
    local argument = tool_call_block.argument or ""
    local max_length = self:_get_title_max_length()

    return max_length > 0
        and #argument > max_length
        and tool_call_block.diff == nil
        and self:_title_kind_enabled(tool_call_block.kind)
end

--- @param argument string
--- @return string[] lines
function MessageWriter:_split_title_lines(argument)
    local normalized = argument:gsub("\\n", "\n")
    return vim.split(normalized, "\n", { plain = true })
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines
function MessageWriter:_build_full_title_body_lines(tool_call_block)
    local lang = tool_call_block.kind == "execute" and "bash" or "text"
    local lines = { TITLE_FENCE .. lang }
    vim.list_extend(
        lines,
        self:_split_title_lines(tool_call_block.argument or "")
    )
    table.insert(lines, TITLE_FENCE)

    return lines
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
--- @return string[] lines Array of lines to render
--- @return agentic.ui.MessageWriter.HighlightRange[] highlight_ranges Array of highlight range specifications (relative to returned lines)
function MessageWriter:_prepare_block_lines(tool_call_block)
    local kind = tool_call_block.kind

    local lines = {
        self:_build_header_line(tool_call_block),
        "",
    }

    --- @type agentic.ui.MessageWriter.HighlightRange[]
    local highlight_ranges = {}

    --- @param start_index integer
    --- @param body_lines string[]
    local function add_body_comment_ranges(start_index, body_lines)
        if kind == "edit" or kind == "switch_mode" then
            return
        end

        for offset, line in ipairs(body_lines) do
            if #line > 0 then
                --- @type agentic.ui.MessageWriter.HighlightRange
                local range = {
                    type = "comment",
                    line_index = start_index + offset - 1,
                }
                table.insert(highlight_ranges, range)
            end
        end
    end

    local has_title_body = self:_should_render_full_title_body(tool_call_block)
    if has_title_body then
        vim.list_extend(
            lines,
            self:_build_full_title_body_lines(tool_call_block)
        )
    end

    --- @param has_body boolean
    local function insert_title_separator(has_body)
        if has_title_body and has_body then
            vim.list_extend(lines, { "", "---", "" })
        end
    end

    if kind == "read" then
        -- Count lines from content, we don't want to show full content that was read
        local line_count = tool_call_block.body and #tool_call_block.body or 0

        if line_count > 0 then
            insert_title_separator(true)
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
        table.insert(lines, "`````" .. lang)

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

        table.insert(lines, "`````")
    else
        if tool_call_block.body and #tool_call_block.body > 0 then
            insert_title_separator(true)
            local body_start_index = #lines
            vim.list_extend(lines, tool_call_block.body)
            add_body_comment_ranges(body_start_index, tool_call_block.body)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "")

    return lines, highlight_ranges
end

--- Set or clear the permission state for a tool call block.
--- @param tool_call_id string
--- @param state agentic.ui.MessageWriter.PermissionState|nil nil to clear
function MessageWriter:set_permission_state(tool_call_id, state)
    local tracker = self.tool_call_blocks[tool_call_id]
    if not tracker then
        return
    end
    tracker.permission = state
end

--- @param tool_call_id string
--- @return integer|nil index 1-indexed focused button or nil when no permission state
function MessageWriter:get_focused_button_index(tool_call_id)
    local tracker = self.tool_call_blocks[tool_call_id]
    if not tracker or not tracker.permission then
        return nil
    end
    return tracker.permission.focused_button_index
end

--- @param tool_call_id string
--- @param index integer 1-indexed button position
--- @return integer|nil col 0-indexed start column of the Nth permission button, or nil
function MessageWriter:get_button_col(tool_call_id, index)
    local tracker = self.tool_call_blocks[tool_call_id]
    if not tracker or not tracker.permission then
        return nil
    end

    local _, segments = self:_build_status_row(tracker)
    -- segments[1] is the status word; segments[1 + i] is the i-th button.
    local seg = segments[1 + index]
    if not seg then
        return nil
    end

    return seg[1]
end

--- Recompute and write the status row (row N) for the given tool call block.
--- Used by both the writer itself (initial render / updates) and the
--- PermissionManager when toggling buttons / focus.
--- @param tool_call_id string
function MessageWriter:repaint_status_row(tool_call_id)
    local tracker = self.tool_call_blocks[tool_call_id]

    if not tracker then
        return
    end

    local end_row = self:get_block_end_row(tool_call_id)

    if not end_row then
        return
    end

    local text, hl_segments = self:_build_status_row(tracker)
    self:_render_status_row(end_row, text, hl_segments)
end

--- Return the 0-indexed last row of the block, or nil when no block tracker
--- or extmark is found.
--- @param tool_call_id string
--- @return integer|nil start_row
function MessageWriter:_get_block_start_row(tool_call_id)
    local tracker = self.tool_call_blocks[tool_call_id]

    if not tracker or not tracker.extmark_id then
        return nil
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        {}
    )

    return pos and pos[1]
end

--- @param tool_call_id string
--- @return integer|nil end_row
function MessageWriter:get_block_end_row(tool_call_id)
    local tracker = self.tool_call_blocks[tool_call_id]

    if not tracker or not tracker.extmark_id then
        return nil
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        return nil
    end

    return pos[3] and pos[3].end_row
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

            BufHelpers.with_modifiable(self.bufnr, function(bufnr)
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

--- Apply semantic highlights to block content.
--- @param _bufnr integer
--- @param start_row integer Header line number
--- @param _end_row integer Footer line number
--- @param _kind string Tool call kind
--- @param highlight_ranges agentic.ui.MessageWriter.HighlightRange[] Diff highlight ranges
function MessageWriter:_apply_block_highlights(
    _bufnr,
    start_row,
    _end_row,
    _kind,
    highlight_ranges
)
    if #highlight_ranges > 0 then
        self:_apply_diff_highlights(start_row, highlight_ranges)
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

--- @class agentic.ui.MessageWriter.StatusSegment
--- @field [1] integer start_col 0-indexed inclusive
--- @field [2] integer end_col 0-indexed exclusive
--- @field [3] string hl_group

--- Build the text + highlight segments for the status row (row N) of a block.
--- Pending blocks with an attached PermissionState include inline buttons.
--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @return string text
--- @return agentic.ui.MessageWriter.StatusSegment[] segments
function MessageWriter:_build_status_row(tracker)
    local status = tracker.status

    if not status or status == "" then
        return "", {}
    end

    local icons = Config.status_icons or {}
    local icon = icons[status] or ""
    local status_label = icon ~= "" and (icon .. " " .. status) or status

    local text = " " .. status_label .. " "
    --- @type agentic.ui.MessageWriter.StatusSegment[]
    local segments = {
        { 0, #text, Theme.get_status_hl_group(status) },
    }

    local perm = tracker.permission

    if status ~= "pending" or not perm then
        return text, segments
    end

    local permission_icons = Config.permission_icons or {}
    local focused_btn = perm.focused_button_index

    for i, option in ipairs(perm.sorted_options) do
        local label = PERMISSION_OPTION_LABELS[option.kind] or option.kind
        local btn_icon = permission_icons[option.kind] or ""
        local body = ""

        if perm.is_focused then
            body = string.format("%d %s %s", i, btn_icon, label)
        else
            body = string.format("%s %s", btn_icon, label)
        end

        local btn = " " .. body .. " "

        text = text .. "  "
        local start_col = #text
        text = text .. btn
        local end_col = #text

        local is_button_focused = perm.is_focused and i == focused_btn
        local hl_group

        if not is_button_focused then
            hl_group = Theme.HL_GROUPS.PERMISSION_BUTTON_INACTIVE
        elseif option.kind == "allow_once" or option.kind == "allow_always" then
            hl_group = Theme.HL_GROUPS.PERMISSION_BUTTON_ALLOW
        else
            hl_group = Theme.HL_GROUPS.PERMISSION_BUTTON_REJECT
        end
        table.insert(segments, { start_col, end_col, hl_group })
    end

    return text, segments
end

--- Write text and apply highlight segments at the given row in NS_STATUS.
--- @param row integer 0-indexed row
--- @param text string
--- @param hl_segments agentic.ui.MessageWriter.StatusSegment[]
function MessageWriter:_render_status_row(row, text, hl_segments)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    BufHelpers.with_modifiable(self.bufnr, function(bufnr)
        pcall(vim.api.nvim_buf_set_lines, bufnr, row, row + 1, false, { text })
    end)

    pcall(vim.api.nvim_buf_clear_namespace, self.bufnr, NS_STATUS, row, row + 1)

    for _, seg in ipairs(hl_segments) do
        vim.api.nvim_buf_set_extmark(self.bufnr, NS_STATUS, row, seg[1], {
            end_col = seg[2],
            hl_group = seg[3],
        })
    end
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

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_apply_status_highlights_if_present(tracker)
    if not tracker.status then
        return
    end
    local start_row = self:_get_block_start_row(tracker.tool_call_id)
    if not start_row then
        return
    end
    self:_apply_header_highlight(start_row, tracker.status)
    self:repaint_status_row(tracker.tool_call_id)
end

function MessageWriter:destroy() end

return MessageWriter
