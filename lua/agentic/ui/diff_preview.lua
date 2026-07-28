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

--- @param state agentic.ui.DiffState
--- @return number|nil bufnr
function M.get_active_diff_buffer(state)
    if state.split_state then
        return state.split_state.original_bufnr
    end

    return state.preview_bufnr
end

--- @param lines string[]
--- @param lang string
--- @return table<number, table<number, string>>|nil row_col_hl row -> col -> hl_group
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

--- @param col integer 0-indexed
--- @param change table|nil From `find_inline_change`
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- @param line string
--- @param change table|nil From `find_inline_change`
--- @return table[] segments
local function build_plain_segments(line, change)
    if not change then
        return { { line, Theme.HL_GROUPS.DIFF_ADD } }
    end

    local segments = {}
    local before = line:sub(1, change.new_start)
    local changed = line:sub(change.new_start + 1, change.new_end)
    local after = line:sub(change.new_end + 1)

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

--- @param line string
--- @param col_hl table<number, string>
--- @param change table|nil From `find_inline_change`
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
            local hl_spec = current_hl and { current_hl, current_diff_hl }
                or current_diff_hl
            table.insert(segments, { text, hl_spec })
            seg_start = col
            current_hl = hl
            current_diff_hl = diff_hl
        end
    end

    local text = line:sub(seg_start + 1)
    if #text > 0 then
        local hl_spec = current_hl and { current_hl, current_diff_hl }
            or current_diff_hl
        table.insert(segments, { text, hl_spec })
    end

    return #segments > 0 and segments or { { line, Theme.HL_GROUPS.DIFF_ADD } }
end

--- @param pairs agentic.ui.ToolCallDiff.ChangedPair[]
--- @return (string|nil)[]|nil aligned Matches `filtered.new_lines` order; nil when nothing was modified
local function build_aligned_old_lines(pairs)
    --- @type (string|nil)[]
    local aligned = {}
    local has_modifications = false

    for _, pair in ipairs(pairs) do
        if pair.new_line then
            table.insert(aligned, pair.old_line)
            if pair.old_line then
                has_modifications = true
            end
        end
    end

    return has_modifications and aligned or nil
end

--- @param new_lines string[]
--- @param old_lines (string|nil)[]|nil Aligned with `new_lines`
--- @param lang string
--- @return table virt_lines
local function get_highlighted_virt_lines(new_lines, old_lines, lang)
    local row_col_hl = build_highlight_map(new_lines, lang)

    local virt_lines = {}
    for row, line in ipairs(new_lines) do
        local col_hl = row_col_hl and row_col_hl[row - 1]

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
--- @field get_winid fun(bufnr: number): number|nil Called when the buffer is not already visible
--- @field state? agentic.ui.DiffState Mutated in place
--- @field tabpage? integer Scopes the already-visible window lookup

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    -- Normal mode only, so the diff cannot disrupt an edit in progress.
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "n" then
        Logger.debug("show_diff: skipped, not in normal mode:", mode)
        return
    end

    if Config.diff_preview.layout == "split" then
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
        strict = true,
    })

    if #diff_blocks == 0 then
        -- An empty diff is valid: a Write tool's content arrives in updates.
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

    -- Tab-scoped, or a copy open elsewhere pulls the diff into a foreign tab.
    local winid = BufHelpers.find_visible_win(bufnr, nil, opts.tabpage)
    local target_winid = winid or opts.get_winid(bufnr)
    if not target_winid then
        return
    end

    M.clear_diff(bufnr, nil, opts.state)

    for _, block in ipairs(diff_blocks) do
        local old_count = #block.old_lines
        local new_count = #block.new_lines

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
                        pair.new_line
                    )
                end
            end
        end

        if new_count > 0 and #filtered.new_lines > 0 then
            -- Virtual lines render BELOW their anchor: a pure insertion anchors
            -- on the line above the insertion point, anything else on the last deleted line.
            local anchor_1indexed = old_count == 0 and block.start_line - 1
                or block.end_line
            local anchor_line = math.max(0, anchor_1indexed - 1)

            local ft = vim.bo[bufnr].filetype
            local lang = vim.treesitter.language.get_lang(ft) or ft

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

    if #diff_blocks > 0 then
        if opts.state then
            opts.state.preview_bufnr = bufnr
            -- Read by hunk navigation and the rejection swap, so they act on
            -- this window rather than another tab's view of the same file.
            opts.state.preview_winid = target_winid
        end

        -- Read-only while the diff is visible.
        vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
        vim.bo[bufnr].modifiable = false

        HunkNavigation.setup_keymaps(bufnr, opts.state)

        vim.schedule(function()
            HunkNavigation.navigate_next(bufnr, opts.state)
        end)
    end
end

--- @param buf number|string Buffer number or file path
--- @param is_rejection boolean|nil Deletes the buffer when the file does not exist
--- @param state agentic.ui.DiffState|nil nil leaves state untouched
function M.clear_diff(buf, is_rejection, state)
    local bufnr = type(buf) == "string" and vim.fn.bufnr(buf) or buf --[[@as integer]]

    if bufnr == -1 and type(buf) == "string" then
        local smart = FileSystem.to_smart_path(buf)
        local smart_bufnr = vim.fn.bufnr(smart)
        if smart_bufnr ~= -1 and vim.b[smart_bufnr]._agentic_suggestion_for then
            bufnr = smart_bufnr
        end
    end

    if bufnr == -1 then
        return
    end

    -- Captured before the clear below; the rejection swap still needs it.
    local painted_winid = state and state.preview_winid

    if state then
        if state.split_state then
            DiffSplitView.clear_split_diff(state)
            return
        end
        state.preview_bufnr = nil
        state.preview_winid = nil
    end

    HunkNavigation.restore_keymaps(bufnr)

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)

    local is_suggestion = vim.b[bufnr]._agentic_suggestion_for ~= nil

    -- Suggestion buffers keep their text visible until the real file takes over.
    if not is_suggestion then
        local prev_modifiable = vim.b[bufnr]._agentic_prev_modifiable
        if prev_modifiable ~= nil then
            vim.bo[bufnr].modifiable = prev_modifiable
            vim.b[bufnr]._agentic_prev_modifiable = nil
        end
    end

    -- A rejected new file has nothing on disk, so the window needs another buffer.
    if is_rejection then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        local stat = file_path ~= "" and vim.uv.fs_stat(file_path)

        if not stat then
            local buf_winid = BufHelpers.find_visible_win(bufnr, painted_winid)
            if buf_winid then
                -- The TARGET window's alternate buffer, not the current one's.
                local alt = vim.api.nvim_win_call(buf_winid, function()
                    return vim.fn.bufnr("#")
                end)

                local target_buf = (alt ~= -1 and alt ~= bufnr) and alt
                    or vim.api.nvim_create_buf(true, true)

                pcall(vim.api.nvim_win_set_buf, buf_winid, target_buf)
            end
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
end

--- @param tracker table|nil
--- @param lines_to_append string[] Appended to in place
--- @return number|nil hint_line_index nil when no hint was added
function M.add_navigation_hint(tracker, lines_to_append)
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

--- @param bufnr number
--- @param ns_id number
--- @param button_start_row number
--- @param hint_line_index number
function M.apply_hint_styling(bufnr, ns_id, button_start_row, hint_line_index)
    pcall(function()
        local hint_line_row = button_start_row + hint_line_index
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

--- Lets the widget buffers drive hunk navigation in the active diff buffer.
--- @param buf_nrs table<string, number>
--- @param state agentic.ui.DiffState Captured by the closures
function M.setup_diff_navigation_keymaps(buf_nrs, state)
    local diff_keymaps = Config.keymaps.diff_preview

    local directions = {
        {
            lhs = diff_keymaps.next_hunk,
            navigate = HunkNavigation.navigate_next,
            desc = "Go to next hunk - Agentic DiffPreview",
        },
        {
            lhs = diff_keymaps.prev_hunk,
            navigate = HunkNavigation.navigate_prev,
            desc = "Go to previous hunk - Agentic DiffPreview",
        },
    }

    for _, bufnr in pairs(buf_nrs) do
        for _, direction in ipairs(directions) do
            BufHelpers.keymap_set(bufnr, "n", direction.lhs, function()
                local diff_bufnr = M.get_active_diff_buffer(state)
                if not diff_bufnr then
                    Logger.notify("No active diff preview", vim.log.levels.INFO)
                    return
                end
                direction.navigate(diff_bufnr, state)
            end, { desc = direction.desc })
        end
    end
end

--- Real text rather than virtual lines, so a new file's diff scrolls.
--- @param opts agentic.ui.DiffPreview.ShowOpts
--- @param new_lines string[]
function M._show_new_file_diff(opts, new_lines)
    local suggestion_name = FileSystem.to_smart_path(opts.file_path)
    local bufnr = vim.fn.bufnr(suggestion_name)
    if bufnr == -1 then
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, suggestion_name)
    end

    vim.bo[bufnr].buflisted = false
    vim.b[bufnr]._agentic_suggestion_for = opts.file_path

    -- The real path, since the smart-path name has no usable extension.
    local ft = vim.filetype.match({ filename = opts.file_path })
    if ft then
        vim.bo[bufnr].filetype = ft
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

    vim.api.nvim_buf_set_extmark(bufnr, NS_DIFF, 0, 0, {
        end_row = #new_lines - 1,
        end_col = #new_lines[#new_lines],
        hl_group = Theme.HL_GROUPS.DIFF_ADD,
        hl_eol = true,
    })

    vim.bo[bufnr].modifiable = false

    -- Deleted rather than orphaned when no window can show it.
    local winid = opts.get_winid(bufnr)
    if not winid then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
end

--- Called when a file-mutating tool call completes.
--- @param file_path string|nil
function M.cleanup_suggestion_buffer(file_path)
    if not file_path then
        return
    end

    local suggestion_name = FileSystem.to_smart_path(file_path)
    local suggestion_bufnr = vim.fn.bufnr(suggestion_name)
    if
        suggestion_bufnr == -1
        or not vim.b[suggestion_bufnr]._agentic_suggestion_for
    then
        return
    end

    local winid = BufHelpers.find_visible_win(suggestion_bufnr)

    -- Deleted before `bufadd`: nvim path resolution can match the smart-path
    -- name to the absolute path. The temp buffer keeps the window alive.
    if winid then
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
end

return M
