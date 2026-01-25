local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- Hunk navigation module for diff preview
--- Manages navigation state, keymaps, and movement between diff hunks
--- @class agentic.ui.HunkNavigation
local M = {}

--- Namespace for diff preview extmarks
M.NS_DIFF = vim.api.nvim_create_namespace("agentic_diff_preview")
local NS_DIFF = M.NS_DIFF

--- Per-buffer state for hunk navigation
--- needed because `vim.b` doesn't support saving callbacks, as it will serialize, to comply with vimscript
--- @class agentic.ui.HunkNavigation.State
--- @field saved_keymaps { next?: table, prev?: table } Saved keymaps for restoration
--- @field anchors_cache integer[]|nil Cached hunk anchor positions (0-indexed line numbers)

--- Module-level state storage (per-buffer)
--- @type table<number, agentic.ui.HunkNavigation.State>
local buffer_state = {}

--- Get or initialize state for buffer
--- @param bufnr number
--- @return agentic.ui.HunkNavigation.State
local function get_state(bufnr)
    if not buffer_state[bufnr] then
        buffer_state[bufnr] = {
            saved_keymaps = {},
            anchors_cache = nil,
        }
    end
    return buffer_state[bufnr]
end

--- Get all hunk positions (first deleted line per hunk)
--- Falls back to virtual line anchor for pure insertions.
--- Groups consecutive deleted lines (only returns first line of each group).
--- @param bufnr number
--- @return integer[] positions 0-indexed line numbers where hunks begin
function M._get_hunk_anchors(bufnr)
    local state = get_state(bufnr)
    if state.anchors_cache then
        return state.anchors_cache
    end

    local extmarks =
        vim.api.nvim_buf_get_extmarks(bufnr, NS_DIFF, 0, -1, { details = true })

    local deleted_lines = {}
    local virt_line_anchors = {}

    for _, extmark in ipairs(extmarks) do
        local _, row, _, details = unpack(extmark)

        if details then
            if details.hl_group then
                local hl = details.hl_group
                if
                    hl == Theme.HL_GROUPS.DIFF_DELETE
                    or hl == Theme.HL_GROUPS.DIFF_DELETE_WORD
                then
                    deleted_lines[row] = true
                end
            end

            if details.virt_lines then
                virt_line_anchors[row] = true
            end
        end
    end

    local deleted_positions = {}
    for line_num in pairs(deleted_lines) do
        table.insert(deleted_positions, line_num)
    end
    table.sort(deleted_positions)

    local positions = {}
    local prev_line = -2

    for _, line_num in ipairs(deleted_positions) do
        if line_num > prev_line + 1 then
            table.insert(positions, line_num)
        end
        prev_line = line_num
    end

    if #positions == 0 then
        for anchor in pairs(virt_line_anchors) do
            table.insert(positions, anchor)
        end
        table.sort(positions)
    end

    if #positions == 0 then
        positions = { 0 }
    end

    state.anchors_cache = positions
    return positions
end

--- Find next/previous hunk position relative to buffer's cursor position
--- @param bufnr number
--- @param direction "next"|"prev"
--- @return number|nil target_line 1-indexed line number
local function find_hunk(bufnr, direction)
    local anchors = M._get_hunk_anchors(bufnr)
    if #anchors == 0 then
        return nil
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local current_line = cursor[1] - 1 -- 0-indexed

    local current_index = -1
    local is_exactly_on_anchor = false

    for i, anchor in ipairs(anchors) do
        if anchor == current_line then
            current_index = i - 1
            is_exactly_on_anchor = true
            break
        elseif anchor < current_line then
            current_index = i - 1
        else
            break
        end
    end

    local new_index
    if direction == "next" then
        new_index = (current_index + 1) % #anchors
    else
        if is_exactly_on_anchor then
            new_index = current_index <= 0 and #anchors - 1 or current_index - 1
        else
            new_index = current_index < 0 and #anchors - 1 or current_index
        end
    end

    return anchors[new_index + 1] + 1 -- 1-indexed
end

--- Calculate scroll command based on hunk size and window height
--- @param bufnr number
--- @param winid number
--- @param anchor_line number 0-indexed anchor line
--- @return string scroll_cmd "zt", "zz", or empty string if centering disabled or no extmarks
function M.get_scroll_cmd(bufnr, winid, anchor_line)
    if not Config.diff_preview.center_on_navigate_hunks then
        return ""
    end

    local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_DIFF,
        { anchor_line, 0 },
        { anchor_line, -1 },
        { details = true }
    )

    if #extmarks == 0 then
        return ""
    end

    local details = extmarks[1] and extmarks[1][4] or {}
    local virt_lines = details.virt_lines or {}
    local hunk_height = #virt_lines

    local win_height = vim.api.nvim_win_get_height(winid)

    return hunk_height > (win_height / 2) and "zt" or "zz"
end

--- Navigate to hunk in specified direction
--- @param bufnr number
--- @param direction "next"|"prev"
local function navigate_hunk(bufnr, direction)
    local target_winid = vim.fn.bufwinid(bufnr)
    if target_winid == -1 then
        Logger.notify("Buffer not visible in any window", vim.log.levels.WARN)
        return
    end

    if Config.diff_preview.layout == "split" then
        local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, target_winid)
        if not ok then
            return
        end

        local DiffSplitView = require("agentic.ui.diff_split_view")
        local split_state = DiffSplitView.get_split_state(tabpage)

        if split_state then
            local diff_cmd = direction == "next" and "]c" or "[c"
            local center_cmd = Config.diff_preview.center_on_navigate_hunks
                    and "zz"
                or ""

            local nav_ok = pcall(vim.api.nvim_win_call, target_winid, function()
                vim.cmd("normal! " .. diff_cmd .. center_cmd)
            end)

            if not nav_ok then
                Logger.notify(
                    "No more hunks in this direction",
                    vim.log.levels.INFO
                )
            end
            return
        end
    end

    local target_line = find_hunk(bufnr, direction)
    if not target_line then
        Logger.notify("No hunks found", vim.log.levels.INFO)
        return
    end

    local anchor_line = target_line - 1
    local scroll_cmd = M.get_scroll_cmd(bufnr, target_winid, anchor_line)

    pcall(vim.api.nvim_win_call, target_winid, function()
        vim.cmd(string.format("normal! %dG%s", target_line, scroll_cmd))
    end)
end

--- Save existing keymap for restoration
--- @param bufnr number
--- @param key string
--- @return table|nil map_info
local function save_keymap(bufnr, key)
    local map_info
    vim.api.nvim_buf_call(bufnr, function()
        map_info = vim.fn.maparg(key, "n", false, true)
    end)

    if map_info and map_info.lhs then
        -- vim.fn.maparg() returns buffer=1 as a flag indicating buffer-local mapping
        -- (not the actual buffer number). We only save buffer-local keymaps.
        if map_info.buffer == 1 then
            return map_info
        end
    end
    return nil
end

--- Navigate to next hunk
--- @param bufnr number
function M.navigate_next(bufnr)
    navigate_hunk(bufnr, "next")
end

--- Navigate to previous hunk
--- @param bufnr number
function M.navigate_prev(bufnr)
    navigate_hunk(bufnr, "prev")
end

--- Setup hunk navigation keymaps for buffer
--- @param bufnr number
function M.setup_keymaps(bufnr)
    local keymaps = Config.keymaps.diff_preview
    local state = get_state(bufnr)
    state.saved_keymaps.next = save_keymap(bufnr, keymaps.next_hunk)
    state.saved_keymaps.prev = save_keymap(bufnr, keymaps.prev_hunk)

    BufHelpers.keymap_set(bufnr, "n", keymaps.next_hunk, function()
        M.navigate_next(bufnr)
    end, { desc = "Go to next hunk - Agentic DiffPreview" })

    BufHelpers.keymap_set(bufnr, "n", keymaps.prev_hunk, function()
        M.navigate_prev(bufnr)
    end, { desc = "Go to previous hunk - Agentic DiffPreview" })
end

--- Restore saved keymaps for buffer
--- @param bufnr number
function M.restore_keymaps(bufnr)
    local keymaps = Config.keymaps.diff_preview
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", keymaps.next_hunk)
    pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", keymaps.prev_hunk)

    local state = buffer_state[bufnr]
    if state and state.saved_keymaps then
        for _, saved_map in pairs(state.saved_keymaps) do
            if saved_map and saved_map.lhs then
                local opts = { buffer = bufnr }
                if saved_map.noremap == 1 then
                    opts.noremap = true
                end
                if saved_map.silent == 1 then
                    opts.silent = true
                end
                if saved_map.expr == 1 then
                    opts.expr = true
                end
                if saved_map.nowait == 1 then
                    opts.nowait = true
                end

                pcall(
                    BufHelpers.keymap_set,
                    bufnr,
                    "n",
                    saved_map.lhs,
                    saved_map.callback or saved_map.rhs,
                    opts
                )
            end
        end
    end

    M.clear_state(bufnr)
end

--- Clear all module state for buffer
--- @param bufnr number
function M.clear_state(bufnr)
    buffer_state[bufnr] = nil
end

return M
