local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffSplitView = require("agentic.ui.diff_split_view")
local FileSystem = require("agentic.utils.file_system")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

local NS_DIFF = HunkNavigation.NS_DIFF
local LEGACY_OWNER = "legacy"

--- @param state agentic.ui.DiffState|nil
--- @return string owner
local function owner_for(state)
    return state and tostring(state) or LEGACY_OWNER
end

--- @param state agentic.ui.DiffState|nil
--- @return string identity
local function state_identity(state)
    return state and tostring(state):gsub("^table: ", "") or LEGACY_OWNER
end

--- @param bufnr integer
local function delete_buffer_without_closing_windows(bufnr)
    -- EVERY window, not just the painted one: `nvim_buf_delete(force)` closes
    -- each window still holding the buffer.
    for _, buf_winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if BufHelpers.is_win_usable(buf_winid) then
            local ok, alt = pcall(vim.api.nvim_win_call, buf_winid, function()
                return vim.fn.bufnr("#")
            end)
            local target_buf = (ok and alt ~= -1 and alt ~= bufnr) and alt
                or vim.api.nvim_create_buf(false, true)
            pcall(vim.api.nvim_win_set_buf, buf_winid, target_buf)
        end
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

--- @param state agentic.ui.DiffState|nil
--- @param next_bufnr integer
local function retire_previous_inline_preview(state, next_bufnr)
    if not state then
        return
    end

    local previous_bufnr = state.preview_bufnr
    if not previous_bufnr or previous_bufnr == next_bufnr then
        return
    end

    if not vim.api.nvim_buf_is_valid(previous_bufnr) then
        state.preview_bufnr = nil
        state.preview_winid = nil
        return
    end

    if vim.b[previous_bufnr]._agentic_inline_diff_owner ~= owner_for(state) then
        state.preview_bufnr = nil
        state.preview_winid = nil
        return
    end

    local is_suggestion = vim.b[previous_bufnr]._agentic_suggestion_for ~= nil
    HunkNavigation.restore_keymaps(previous_bufnr, state)
    pcall(vim.api.nvim_buf_clear_namespace, previous_bufnr, NS_DIFF, 0, -1)
    vim.b[previous_bufnr]._agentic_inline_diff_owner = nil

    if is_suggestion then
        delete_buffer_without_closing_windows(previous_bufnr)
    else
        local prev_modifiable = vim.b[previous_bufnr]._agentic_prev_modifiable
        if prev_modifiable ~= nil then
            vim.bo[previous_bufnr].modifiable = prev_modifiable
            vim.b[previous_bufnr]._agentic_prev_modifiable = nil
        end
    end

    state.preview_bufnr = nil
    state.preview_winid = nil
end

--- @param file_path string
--- @param state agentic.ui.DiffState|nil
--- @return integer bufnr
local function find_suggestion_buffer(file_path, state)
    local smart_path = FileSystem.to_smart_path(file_path)
    local suggestion_name = state
            and string.format(
                "%s (suggestion %s)",
                smart_path,
                state_identity(state)
            )
        or smart_path
    local bufnr = vim.fn.bufnr(suggestion_name)
    if bufnr ~= -1 and vim.b[bufnr]._agentic_suggestion_for then
        return bufnr
    end
    return -1
end

--- @param state agentic.ui.DiffState
--- @return number|nil bufnr
function M.get_active_diff_buffer(state)
    local split_state = DiffSplitView.find_split_state(state)
    if split_state then
        return split_state.original_bufnr
    end
    return state.preview_bufnr
end

--- Builds a highlight map for all lines parsed as a block
--- @param lines string[]
--- @param lang string
--- @return table<number, table<number, string>>|nil row_col_hl Map of row -> col -> hl_group
local function build_highlight_map(lines, lang)
    if not lang or lang == "" or #lines == 0 then
        return nil
    end

    local content = table.concat(lines, "\n")

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
    if not ok or not parser then
        return nil
    end

    local trees = parser:parse()
    if not trees or #trees == 0 then
        return nil
    end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
        return nil
    end

    local row_col_hl = {}
    for i = 0, #lines - 1 do
        row_col_hl[i] = {}
    end

    for id, node in query:iter_captures(trees[1]:root(), content) do
        local name = query.captures[id]
        local start_row, start_col, end_row, end_col = node:range()
        local hl_group = "@" .. name .. "." .. lang

        for row = start_row, end_row do
            if row_col_hl[row] then
                local col_start = (row == start_row) and start_col or 0
                local col_end = (row == end_row) and end_col or #lines[row + 1]
                for col = col_start, col_end - 1 do
                    row_col_hl[row][col] = hl_group
                end
            end
        end
    end

    return row_col_hl
end

--- Get the diff highlight for a column position based on word-level change
--- Always returns DIFF_ADD for line background, DIFF_ADD_WORD for changed portions
--- @param col integer 0-indexed column
--- @param change table|nil Change info from find_inline_change
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- Builds segments for a line without syntax highlighting
--- @param line string
--- @param change table|nil Change info from find_inline_change
--- @return table[] segments
local function build_plain_segments(line, change)
    if not change then
        return { { line, Theme.HL_GROUPS.DIFF_ADD } }
    end

    local segments = {}
    local before = line:sub(1, change.new_start)
    local changed = line:sub(change.new_start + 1, change.new_end)
    local after = line:sub(change.new_end + 1)

    -- Line-level highlight for unchanged portions, word-level for changed
    if #before > 0 then
        table.insert(segments, { before, Theme.HL_GROUPS.DIFF_ADD })
    end
    if #changed > 0 then
        table.insert(segments, { changed, Theme.HL_GROUPS.DIFF_ADD_WORD })
    end
    if #after > 0 then
        table.insert(segments, { after, Theme.HL_GROUPS.DIFF_ADD })
    end

    return #segments > 0 and segments or { { line, Theme.HL_GROUPS.DIFF_ADD } }
end

--- Builds segments for a line with syntax highlighting
--- @param line string
--- @param col_hl table<number, string>
--- @param change table|nil Change info from find_inline_change
--- @return table[] segments
local function build_highlighted_segments(line, col_hl, change)
    local segments = {}
    local current_hl = col_hl[0]
    local current_diff_hl = get_diff_hl_for_col(0, change)
    local seg_start = 0

    for col = 1, #line do
        local hl = col_hl[col]
        local diff_hl = get_diff_hl_for_col(col, change)
        if hl ~= current_hl or diff_hl ~= current_diff_hl then
            local text = line:sub(seg_start + 1, col)
            -- Build highlight spec: syntax highlight + diff background
            local hl_spec = current_hl and { current_hl, current_diff_hl }
                or current_diff_hl
            table.insert(segments, { text, hl_spec })
            seg_start = col
            current_hl = hl
            current_diff_hl = diff_hl
        end
    end

    -- Final segment
    local text = line:sub(seg_start + 1)
    if #text > 0 then
        local hl_spec = current_hl and { current_hl, current_diff_hl }
            or current_diff_hl
        table.insert(segments, { text, hl_spec })
    end

    return #segments > 0 and segments or { { line, Theme.HL_GROUPS.DIFF_ADD } }
end

--- Build old_lines array aligned with filtered new_lines for word-level diff
--- Iterates pairs in order to match the sequential order of filtered.new_lines
--- @param pairs agentic.ui.ToolCallDiff.ChangedPair[]
--- @return (string|nil)[]|nil aligned Array matching filtered.new_lines order, nil if no modifications
local function build_aligned_old_lines(pairs)
    --- @type (string|nil)[]
    local aligned = {}
    local has_modifications = false

    for _, pair in ipairs(pairs) do
        if pair.new_line then
            -- For each new_line in pairs (which matches filtered.new_lines order),
            -- store the corresponding old_line (nil for pure insertions)
            table.insert(aligned, pair.old_line)
            if pair.old_line then
                has_modifications = true
            end
        end
    end

    return has_modifications and aligned or nil
end

--- Builds virt_lines with syntax highlighting and diff background
--- @param new_lines string[]
--- @param old_lines (string|nil)[]|nil Sequential old lines aligned with new_lines
--- @param lang string
--- @return table virt_lines
local function get_highlighted_virt_lines(new_lines, old_lines, lang)
    local row_col_hl = build_highlight_map(new_lines, lang)

    local virt_lines = {}
    for row, line in ipairs(new_lines) do
        local col_hl = row_col_hl and row_col_hl[row - 1]

        -- Find word-level change if we have corresponding old line
        local old_line = old_lines and old_lines[row]
        local change = old_line
            and DiffHighlighter.find_inline_change(old_line, line)

        local segments = (col_hl and #line > 0)
                and build_highlighted_segments(line, col_hl, change)
            or build_plain_segments(line, change)

        table.insert(virt_lines, segments)
    end

    return virt_lines
end

--- @class agentic.ui.DiffPreview.ShowOpts
--- @field file_path string
--- @field diff agentic.ui.MessageWriter.ToolCallDiff
--- @field get_winid fun(bufnr: number): number|nil Called when buffer is not already visible, should return a winid
--- @field state? agentic.ui.DiffState
--- @field tabpage? integer

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    -- Only show diff in normal mode to avoid disrupting user workflow
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "n" then
        Logger.debug("show_diff: skipped, not in normal mode:", mode)
        return
    end

    if Config.diff_preview.layout == "split" and opts.state then
        local success = DiffSplitView.show_split_diff(opts)
        if success then
            return
        end
        Logger.debug("show_diff: split view failed, falling back to inline")
    end

    if
        ToolCallDiff.is_empty_lines(
            ToolCallDiff.normalize_to_lines(opts.diff.old)
        )
    then
        local abs_path = FileSystem.to_absolute_path(opts.file_path)
        if not vim.uv.fs_stat(abs_path) then
            local new_lines = ToolCallDiff.normalize_to_lines(opts.diff.new)
            if not ToolCallDiff.is_empty_lines(new_lines) then
                M._show_new_file_diff(opts, new_lines)
            end
            return
        end
    end

    local diff_blocks = ToolCallDiff.extract_diff_blocks({
        path = opts.file_path,
        old_text = opts.diff.old,
        new_text = opts.diff.new,
        replace_all = opts.diff.all,
        strict = true, -- don't show fallback if match fails
    })

    if #diff_blocks == 0 then
        -- Empty diff is valid (e.g. new file Write tool where content arrives in updates)
        local new_lines = ToolCallDiff.normalize_to_lines(opts.diff.new or {})
        local old_lines = ToolCallDiff.normalize_to_lines(opts.diff.old or {})
        local has_content = not ToolCallDiff.is_empty_lines(new_lines)
            or not ToolCallDiff.is_empty_lines(old_lines)
        if has_content then
            Logger.notify(
                "Diff preview: could not match diff in " .. opts.file_path,
                vim.log.levels.WARN
            )
        end
        return
    end

    local bufnr = vim.fn.bufnr(opts.file_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(opts.file_path)
    end

    -- Check if buffer is already visible, otherwise request a window
    local owner = owner_for(opts.state)
    local inline_owner = vim.b[bufnr]._agentic_inline_diff_owner
    if inline_owner and inline_owner ~= owner then
        return
    end

    local winid = BufHelpers.find_visible_win(bufnr, nil, opts.tabpage)
    local target_winid = winid or opts.get_winid(bufnr)
    if not target_winid then
        return
    end

    retire_previous_inline_preview(opts.state, bufnr)
    M.clear_diff(bufnr, nil, opts.state)

    for _, block in ipairs(diff_blocks) do
        local old_count = #block.old_lines
        local new_count = #block.new_lines

        -- Filter unchanged lines once and reuse for both old and new highlighting
        local filtered = ToolCallDiff.filter_unchanged_lines(
            block.old_lines,
            block.new_lines
        )

        if old_count > 0 then
            for _, pair in ipairs(filtered.pairs) do
                if pair.old_line and pair.old_idx then
                    local abs_line = block.start_line + pair.old_idx - 1

                    DiffHighlighter.apply_diff_highlights(
                        bufnr,
                        NS_DIFF,
                        abs_line - 1,
                        pair.old_line,
                        pair.new_line -- nil for pure deletions
                    )
                end
            end
        end

        if new_count > 0 and #filtered.new_lines > 0 then
            local anchor_1indexed = old_count == 0 and block.start_line - 1
                or block.end_line
            local anchor_line = math.max(0, anchor_1indexed - 1)

            -- Get treesitter language for syntax highlighting
            local ft = vim.bo[bufnr].filetype
            local lang = vim.treesitter.language.get_lang(ft) or ft

            -- Build old_lines array aligned with new_lines for word-level diff
            local aligned_old_lines = build_aligned_old_lines(filtered.pairs)

            local virt_lines = get_highlighted_virt_lines(
                filtered.new_lines,
                aligned_old_lines,
                lang
            )

            local ok, err = pcall(
                vim.api.nvim_buf_set_extmark,
                bufnr,
                NS_DIFF,
                anchor_line,
                0,
                { virt_lines = virt_lines }
            )
            if not ok then
                Logger.notify("Failed to set virtual lines: " .. tostring(err))
            end
        end
    end

    -- Scroll target window to first diff block without moving cursor
    if #diff_blocks > 0 then
        vim.b[bufnr]._agentic_inline_diff_owner = owner
        if opts.state then
            opts.state.preview_bufnr = bufnr
            opts.state.preview_winid = target_winid
        end

        -- Make buffer read-only to prevent edits while diff is visible
        vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
        vim.bo[bufnr].modifiable = false

        HunkNavigation.setup_keymaps(bufnr, opts.state)

        vim.schedule(function()
            HunkNavigation.navigate_next(bufnr, opts.state)
        end)
    end
end

--- Clears the diff highlights from the given buffer
--- @param buf number|string Buffer number or file path
--- @param is_rejection boolean|nil If true and file doesn't exist, cleanup buffer
--- @param state agentic.ui.DiffState|nil
function M.clear_diff(buf, is_rejection, state)
    if state then
        local split_file_path = type(buf) == "string" and buf or nil
        if not split_file_path and state.split_state then
            for _, split_state in pairs(state.split_state) do
                if
                    split_state.original_bufnr == buf
                    or split_state.new_bufnr == buf
                then
                    split_file_path = split_state.file_path
                    break
                end
            end
        end
        if
            split_file_path
            and DiffSplitView.clear_split_diff(state, split_file_path)
        then
            return
        end
    end
    local bufnr = buf --[[@as integer]]
    if type(buf) == "string" then
        local suggestion_bufnr = find_suggestion_buffer(buf, state)
        if state and suggestion_bufnr ~= -1 then
            bufnr = suggestion_bufnr
        else
            bufnr = vim.fn.bufnr(buf)
            if bufnr == -1 then
                bufnr = suggestion_bufnr
            end
        end
    end

    if bufnr == -1 then
        return
    end

    if vim.b[bufnr]._agentic_inline_diff_owner ~= owner_for(state) then
        return
    end

    local is_suggestion = vim.b[bufnr]._agentic_suggestion_for ~= nil

    HunkNavigation.restore_keymaps(bufnr, state)
    if state and state.preview_bufnr == bufnr then
        state.preview_bufnr = nil
        state.preview_winid = nil
    end
    if not is_suggestion or is_rejection then
        vim.b[bufnr]._agentic_inline_diff_owner = nil
    end

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)

    -- Restore modifiable state if it was saved
    -- (skip for suggestion buffers on acceptance —
    -- text stays visible until real file takes over)
    if not is_suggestion then
        local prev_modifiable = vim.b[bufnr]._agentic_prev_modifiable
        if prev_modifiable ~= nil then
            vim.bo[bufnr].modifiable = prev_modifiable
            vim.b[bufnr]._agentic_prev_modifiable = nil
        end
    end

    -- A rejected new file has nothing on disk, so its windows need another buffer.
    if is_rejection then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        local stat = file_path ~= "" and vim.uv.fs_stat(file_path)

        if not stat then
            delete_buffer_without_closing_windows(bufnr)
        end
    end
end

--- Add hint line for navigation keybindings to permission request
--- @param tracker table|nil Tool call tracker with kind field
--- @param lines_to_append string[] Array of lines to append hint to
--- @return number|nil hint_line_index Index of hint line in array, or nil if not added
function M.add_navigation_hint(tracker, lines_to_append)
    -- Only add hint for edit tools with diff preview enabled
    if
        not tracker
        or tracker.kind ~= "edit"
        or not Config.diff_preview
        or not Config.diff_preview.enabled
    then
        return nil
    end

    local diff_keymaps = Config.keymaps.diff_preview
    local hint_text = string.format(
        "HINT: %s next hunk, %s previous hunk",
        diff_keymaps.next_hunk,
        diff_keymaps.prev_hunk
    )

    local hint_line_index = #lines_to_append
    table.insert(lines_to_append, hint_text)

    return hint_line_index
end

--- Apply low-contrast Comment styling to hint line
--- Wrapped in pcall to prevent blocking user if styling fails
--- @param bufnr number Buffer number
--- @param ns_id number Namespace ID for extmark
--- @param button_start_row number Start row of button block
--- @param hint_line_index number Index of hint line in appended lines
function M.apply_hint_styling(bufnr, ns_id, button_start_row, hint_line_index)
    pcall(function()
        local hint_line_row = button_start_row + hint_line_index
        -- Get the actual line content to determine end column
        local hint_line_content = vim.api.nvim_buf_get_lines(
            bufnr,
            hint_line_row,
            hint_line_row + 1,
            false
        )[1] or ""

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, hint_line_row, 0, {
            end_row = hint_line_row,
            end_col = #hint_line_content,
            hl_group = "Comment",
            hl_eol = false,
        })
    end)
end

--- Setup hunk navigation keymaps for widget buffers
--- Allows navigating hunks in the active diff buffer from widget buffers
--- @param buf_nrs table<string, number>
--- @param state agentic.ui.DiffState
function M.setup_diff_navigation_keymaps(buf_nrs, state)
    local diff_keymaps = Config.keymaps.diff_preview

    for _, bufnr in pairs(buf_nrs) do
        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.next_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer(state)
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_next(diff_bufnr, state)
        end, {
            desc = "Go to next hunk - " .. HunkNavigation.KEYMAP_DESC_SUFFIX,
        })

        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.prev_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer(state)
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_prev(diff_bufnr, state)
        end, {
            desc = "Go to previous hunk - "
                .. HunkNavigation.KEYMAP_DESC_SUFFIX,
        })
    end
end

--- Show diff for a new file using a suggestion buffer with
--- real text content (scrollable, no virtual lines).
--- @param opts agentic.ui.DiffPreview.ShowOpts
--- @param new_lines string[]
function M._show_new_file_diff(opts, new_lines)
    local smart_path = FileSystem.to_smart_path(opts.file_path)
    local suggestion_name = opts.state
            and string.format(
                "%s (suggestion %s)",
                smart_path,
                state_identity(opts.state)
            )
        or smart_path
    local bufnr = vim.fn.bufnr(suggestion_name)
    local created = bufnr == -1
    if created then
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, suggestion_name)
    end

    -- Set buffer properties
    vim.bo[bufnr].buflisted = false
    vim.b[bufnr]._agentic_suggestion_for = opts.file_path
    vim.b[bufnr]._agentic_inline_diff_owner = owner_for(opts.state)

    -- Set filetype from real path
    local ft = vim.filetype.match({ filename = opts.file_path })
    if ft then
        vim.bo[bufnr].filetype = ft
    end

    -- Write content as real text
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

    -- Apply green diff highlights on all lines
    vim.api.nvim_buf_set_extmark(bufnr, NS_DIFF, 0, 0, {
        end_row = #new_lines - 1,
        end_col = #new_lines[#new_lines],
        hl_group = Theme.HL_GROUPS.DIFF_ADD,
        hl_eol = true,
    })

    vim.bo[bufnr].modifiable = false

    -- Display in window; delete orphaned buffer if no window available
    local winid = opts.get_winid(bufnr)
    if not winid then
        if created then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        return
    end
    retire_previous_inline_preview(opts.state, bufnr)
    if opts.state then
        opts.state.preview_bufnr = bufnr
        opts.state.preview_winid = winid
    end
    HunkNavigation.setup_keymaps(bufnr, opts.state)
    vim.schedule(function()
        HunkNavigation.navigate_next(bufnr, opts.state)
    end)
end

--- Replace suggestion buffer with the real file in the same window.
--- Called when a file-mutating tool call completes.
--- @param file_path string|nil
--- @param state agentic.ui.DiffState|nil
function M.cleanup_suggestion_buffer(file_path, state)
    if not file_path then
        return
    end

    local smart_path = FileSystem.to_smart_path(file_path)
    local suggestion_name = state
            and string.format(
                "%s (suggestion %s)",
                smart_path,
                state_identity(state)
            )
        or smart_path
    local suggestion_bufnr = vim.fn.bufnr(suggestion_name)
    if
        suggestion_bufnr == -1
        or not vim.b[suggestion_bufnr]._agentic_suggestion_for
    then
        return
    end

    if
        vim.b[suggestion_bufnr]._agentic_inline_diff_owner ~= owner_for(state)
    then
        return
    end

    local preferred_winid = state and state.preview_winid or nil
    local winid = BufHelpers.find_visible_win(suggestion_bufnr, preferred_winid)

    -- Must delete suggestion buffer before bufadd because Neovim path
    -- resolution can match the smart-path name to the absolute path.
    -- A temporary buffer keeps the window alive during the swap.
    if winid and BufHelpers.is_win_usable(winid) then
        local tmp_bufnr = vim.api.nvim_create_buf(false, true)
        pcall(vim.api.nvim_win_set_buf, winid, tmp_bufnr)
        pcall(vim.api.nvim_buf_delete, suggestion_bufnr, { force = true })

        local abs_path = FileSystem.to_absolute_path(file_path)
        local real_bufnr = vim.fn.bufadd(abs_path)
        pcall(vim.api.nvim_win_set_buf, winid, real_bufnr)
        pcall(vim.api.nvim_buf_delete, tmp_bufnr, { force = true })
    else
        pcall(vim.api.nvim_buf_delete, suggestion_bufnr, { force = true })
    end

    if state and state.preview_bufnr == suggestion_bufnr then
        state.preview_bufnr = nil
        state.preview_winid = nil
    end
end

return M
