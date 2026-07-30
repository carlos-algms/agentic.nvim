local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- @class agentic.ui.HunkNavigation
local M = {}

M.NS_DIFF = vim.api.nvim_create_namespace("agentic_diff_preview")
local NS_DIFF = M.NS_DIFF

--- Keyed by bufnr rather than stored in `vim.b`, which serializes and so cannot hold callbacks.
--- @class agentic.ui.HunkNavigation.State
--- @field saved_keymaps { next?: table, prev?: table }
--- @field anchors_cache integer[]|nil 0-indexed line numbers

--- @type table<number, agentic.ui.HunkNavigation.State>
local buffer_state = {}

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

--- First deleted line per hunk, falling back to the virtual-line anchor for pure insertions.
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

--- @param bufnr number
--- @param direction "next"|"prev"
--- @param preferred_winid integer|nil Window the diff was painted in
--- @return number|nil target_line 1-indexed
local function find_hunk(bufnr, direction, preferred_winid)
    local anchors = M._get_hunk_anchors(bufnr)
    if #anchors == 0 then
        return nil
    end

    local winid = BufHelpers.find_visible_win(bufnr, preferred_winid)
    if not winid then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local current_line = cursor[1] - 1

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

    return anchors[new_index + 1] + 1
end

--- @param bufnr number
--- @param winid number
--- @param anchor_line number 0-indexed
--- @return string scroll_cmd "zt", "zz", or "" when centering is disabled
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

--- `split_state` is keyed by absolute path, so resolve by the bufnr handed in.
--- `DiffSplitView.find_split_state` keys off the CURRENT buffer and returns another
--- file's split whenever the cursor sits outside `bufnr` — reachable, since these
--- keymaps fire on whichever window has focus.
--- @param bufnr number
--- @param diff_state agentic.ui.DiffState|nil
--- @return agentic.ui.DiffSplitView.State|nil state
local function find_split_state_for_buf(bufnr, diff_state)
    local split_states = diff_state and diff_state.split_state
    if not split_states then
        return nil
    end

    for _, state in pairs(split_states) do
        if state.original_bufnr == bufnr or state.new_bufnr == bufnr then
            return state
        end
    end

    return nil
end

--- @param bufnr number
--- @param direction "next"|"prev"
--- @param diff_state agentic.ui.DiffState|nil nil means no split diff
local function navigate_hunk(bufnr, direction, diff_state)
    local split_state = find_split_state_for_buf(bufnr, diff_state)

    -- Any other window is not in diff mode, so `]c` raises E99 and reports
    -- "no more hunks" while the real diff sits in another tab.
    local painted_winid = diff_state
        and (
            diff_state.preview_winid
            or split_state and split_state.original_winid
        )

    local target_winid = BufHelpers.find_visible_win(bufnr, painted_winid)

    -- `find_visible_win` falls back to a GLOBAL `win_findbuf` when the preferred
    -- window is gone: with two sessions diffing one file that drives `]c` through the
    -- other's diff. A session that lost its painted window has nowhere to navigate.
    if painted_winid and target_winid ~= painted_winid then
        Logger.notify("Diff window is no longer available", vim.log.levels.WARN)
        return
    end

    if not target_winid then
        Logger.notify("Buffer not visible in any window", vim.log.levels.WARN)
        return
    end

    if Config.diff_preview.layout == "split" and split_state then
        local diff_cmd = direction == "next" and "]c" or "[c"
        local center_cmd = Config.diff_preview.center_on_navigate_hunks and "zz"
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

    local target_line = find_hunk(bufnr, direction, target_winid)
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

local KEYMAP_DESC_SUFFIX = "Agentic DiffPreview"

--- Buffer-local keymaps only; `maparg`'s `buffer` field is a 0/1 flag, not a buffer number.
---
--- Agentic's own mapping is never saved: two sessions diffing one file both run
--- `setup_keymaps` on it, so the second call would capture the first's `]c` as the
--- "user's" and reinstall it on teardown, dangling on a torn-down session.
--- @param bufnr number
--- @param key string
--- @return table|nil map_info
local function save_keymap(bufnr, key)
    local map_info
    vim.api.nvim_buf_call(bufnr, function()
        map_info = vim.fn.maparg(key, "n", false, true)
    end)

    if not map_info or not map_info.lhs or map_info.buffer ~= 1 then
        return nil
    end

    local desc = map_info.desc
    if type(desc) == "string" and desc:find(KEYMAP_DESC_SUFFIX, 1, true) then
        return nil
    end

    return map_info
end

--- @param bufnr number
--- @param diff_state agentic.ui.DiffState|nil
function M.navigate_next(bufnr, diff_state)
    navigate_hunk(bufnr, "next", diff_state)
end

--- @param bufnr number
--- @param diff_state agentic.ui.DiffState|nil
function M.navigate_prev(bufnr, diff_state)
    navigate_hunk(bufnr, "prev", diff_state)
end

--- @param bufnr number
--- @param diff_state agentic.ui.DiffState|nil Captured by the keymaps
function M.setup_keymaps(bufnr, diff_state)
    local keymaps = Config.keymaps.diff_preview
    local state = get_state(bufnr)
    state.saved_keymaps.next = save_keymap(bufnr, keymaps.next_hunk)
    state.saved_keymaps.prev = save_keymap(bufnr, keymaps.prev_hunk)

    BufHelpers.keymap_set(bufnr, "n", keymaps.next_hunk, function()
        M.navigate_next(bufnr, diff_state)
    end, { desc = "Go to next hunk - " .. KEYMAP_DESC_SUFFIX })

    BufHelpers.keymap_set(bufnr, "n", keymaps.prev_hunk, function()
        M.navigate_prev(bufnr, diff_state)
    end, { desc = "Go to previous hunk - " .. KEYMAP_DESC_SUFFIX })
end

local RESTORED_KEYMAP_FLAGS = { "noremap", "silent", "expr", "nowait" }

--- @param bufnr number
function M.restore_keymaps(bufnr)
    local keymaps = Config.keymaps.diff_preview
    BufHelpers.keymap_del(bufnr, "n", keymaps.next_hunk)
    BufHelpers.keymap_del(bufnr, "n", keymaps.prev_hunk)

    local state = buffer_state[bufnr]
    local saved_keymaps = state and state.saved_keymaps or {}

    for _, saved_map in pairs(saved_keymaps) do
        if saved_map.lhs then
            --- @type vim.keymap.set.Opts
            local opts = {}
            for _, flag in ipairs(RESTORED_KEYMAP_FLAGS) do
                if saved_map[flag] == 1 then
                    opts[flag] = true
                end
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

    M.clear_state(bufnr)
end

--- Clear all module state for buffer
--- @param bufnr number
function M.clear_state(bufnr)
    buffer_state[bufnr] = nil
end

return M
