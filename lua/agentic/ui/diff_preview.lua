local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffHighlighter = require("agentic.utils.diff_highlighter")
local DiffSplitView = require("agentic.ui.diff_split_view")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Displays the edit tool call diff in the actual buffer using virtual lines and highlights
--- @class agentic.ui.DiffPreview
local M = {}

local NS_DIFF = HunkNavigation.NS_DIFF

--- Get diff preview buffer from tabpage
--- @param tabpage number Tabpage ID
--- @return number|nil bufnr
local function get_diff_bufnr(tabpage)
    return vim.t[tabpage]._agentic_diff_preview_bufnr
end

--- Set diff preview buffer for tabpage
--- @param tabpage number Tabpage ID
--- @param bufnr number|nil Buffer number (nil to clear)
local function set_diff_bufnr(tabpage, bufnr)
    vim.t[tabpage]._agentic_diff_preview_bufnr = bufnr
end

--- Get the buffer number with active diff preview for the current or specified tabpage
--- @param tabpage? number Tabpage ID (defaults to current tabpage)
--- @return number|nil bufnr Buffer number with active diff, or nil if none
function M.get_active_diff_buffer(tabpage)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()

    local split_state = DiffSplitView.get_split_state(tab)
    if split_state then
        return split_state.original_bufnr
    end

    return get_diff_bufnr(tab)
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
--- @param change? table Change info from find_inline_change
--- @return string hl_group
local function get_diff_hl_for_col(col, change)
    if change and col >= change.new_start and col < change.new_end then
        return Theme.HL_GROUPS.DIFF_ADD_WORD
    end
    return Theme.HL_GROUPS.DIFF_ADD
end

--- Builds segments for a line without syntax highlighting
--- @param line string
--- @param change? table Change info from find_inline_change
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
--- @param change? table Change info from find_inline_change
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
--- @param old_lines? (string|nil)[] Sequential old lines aligned with new_lines
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

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_diff(opts)
    -- Only show diff in normal mode to avoid disrupting user workflow
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

    local bufnr = vim.fn.bufnr(opts.file_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(opts.file_path)
    end

    -- Check if buffer is already visible, otherwise request a window
    local winid = vim.fn.bufwinid(bufnr)
    local target_winid = winid ~= -1 and winid or opts.get_winid(bufnr)
    if not target_winid then
        return
    end

    M.clear_diff(bufnr)

    local diff_blocks = ToolCallDiff.extract_diff_blocks({
        path = opts.file_path,
        old_text = opts.diff.old,
        new_text = opts.diff.new,
        replace_all = opts.diff.all,
        strict = true, -- don't show fallback if match fails
    })

    if #diff_blocks == 0 then
        Logger.debug("show_diff: no diff blocks matched for", opts.file_path)
    end

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
                    -- Convert to 0-indexed: (start_line + old_idx - 1) gives 1-indexed absolute line,
                    -- then -1 for 0-indexed Neovim API = total -2
                    local line = block.start_line + pair.old_idx - 2

                    DiffHighlighter.apply_diff_highlights(
                        bufnr,
                        NS_DIFF,
                        line,
                        pair.old_line,
                        pair.new_line -- nil for pure deletions
                    )
                end
            end
        end

        if new_count > 0 then
            -- Skip virtual lines if all lines were unchanged
            if #filtered.new_lines == 0 then
                goto continue
            end

            -- Virtual lines appear below anchor (0-indexed)
            local anchor_line
            if old_count == 0 then
                -- Pure insertion: anchor is line before insertion point
                -- start_line is 1-indexed, -1 for 0-indexed, -1 for line above = -2
                anchor_line = math.max(0, block.start_line - 2)
            else
                -- Modification/deletion: anchor is the last deleted line
                -- end_line is 1-indexed, -1 for 0-indexed
                anchor_line = math.max(0, block.end_line - 1)
            end

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

        ::continue::
    end

    -- Scroll target window to first diff block without moving cursor
    if #diff_blocks > 0 then
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, target_winid)
        if not ok then
            return
        end
        set_diff_bufnr(tabpage, bufnr)

        -- Make buffer read-only to prevent edits while diff is visible
        vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
        vim.bo[bufnr].modifiable = false

        HunkNavigation.setup_keymaps(bufnr)

        vim.schedule(function()
            HunkNavigation.navigate_next(bufnr)
        end)
    end
end

--- Clears the diff highlights from the given buffer
--- @param buf number|string Buffer number or file path
--- @param is_rejection? boolean If true and file doesn't exist, cleanup buffer
function M.clear_diff(buf, is_rejection)
    local bufnr = type(buf) == "string" and vim.fn.bufnr(buf) or buf --[[@as integer]]

    if bufnr == -1 then
        return
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, winid)
        if ok then
            if DiffSplitView.get_split_state(tabpage) then
                DiffSplitView.clear_split_diff(tabpage)
                return
            end
            set_diff_bufnr(tabpage, nil)
        end
    end

    HunkNavigation.restore_keymaps(bufnr)

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS_DIFF, 0, -1)

    -- Restore modifiable state if it was saved
    local prev_modifiable = vim.b[bufnr]._agentic_prev_modifiable
    if prev_modifiable ~= nil then
        vim.bo[bufnr].modifiable = prev_modifiable
        vim.b[bufnr]._agentic_prev_modifiable = nil
    end

    -- On rejection for new files, switch window to alternate buffer
    if is_rejection then
        local file_path = vim.api.nvim_buf_get_name(bufnr)
        local stat = file_path ~= "" and vim.uv.fs_stat(file_path)

        if not stat then
            local buf_winid = vim.fn.bufwinid(bufnr)
            if buf_winid ~= -1 then
                -- Get alternate buffer for the target window, not current window
                local alt = vim.api.nvim_win_call(buf_winid, function()
                    return vim.fn.bufnr("#")
                end)

                local target_buf
                if alt ~= -1 and alt ~= bufnr then
                    target_buf = alt
                else
                    target_buf = vim.api.nvim_create_buf(true, true)
                end
                pcall(vim.api.nvim_win_set_buf, buf_winid, target_buf)
            end
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
    end
end

--- Add hint line for navigation keybindings to permission request
--- @param tracker? table Tool call tracker with kind field
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
function M.setup_diff_navigation_keymaps(buf_nrs)
    local diff_keymaps = Config.keymaps.diff_preview

    for _, bufnr in pairs(buf_nrs) do
        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.next_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer()
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_next(diff_bufnr)
        end, {
            desc = "Go to next hunk - Agentic DiffPreview",
        })

        BufHelpers.keymap_set(bufnr, "n", diff_keymaps.prev_hunk, function()
            local diff_bufnr = M.get_active_diff_buffer()
            if not diff_bufnr then
                Logger.notify("No active diff preview", vim.log.levels.INFO)
                return
            end
            HunkNavigation.navigate_prev(diff_bufnr)
        end, {
            desc = "Go to previous hunk - Agentic DiffPreview",
        })
    end
end

return M
