local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Handles side-by-side diff view using Neovim's native :diffthis command
--- @class agentic.ui.DiffSplitView
local M = {}

--- Stored on `agentic.ui.DiffState`
--- @class agentic.ui.DiffSplitView.State
--- @field original_winid number
--- @field original_bufnr number
--- @field new_winid number Scratch buffer's window
--- @field new_bufnr number Scratch buffer
--- @field file_path string

--- Reconstructs the full modified file from the agent's partial diffs.
--- @param original_lines string[]
--- @param old_lines string[]
--- @param new_lines string[]
--- @param replace_all boolean|nil Replace every match rather than the first
--- @return string[]|nil modified_lines nil when the diff did not match
local function reconstruct_modified_file(
    original_lines,
    old_lines,
    new_lines,
    replace_all
)
    local blocks = ToolCallDiff.match_or_substring_fallback(
        original_lines,
        old_lines,
        new_lines
    )

    if not blocks or #blocks == 0 then
        return nil
    end

    if not replace_all then
        blocks = { blocks[1] }
    end

    local modified_lines = vim.deepcopy(original_lines)

    -- Reverse order keeps the line indices of the remaining blocks valid.
    for i = #blocks, 1, -1 do
        local block = blocks[i]

        for j = block.end_line, block.start_line, -1 do
            table.remove(modified_lines, j)
        end

        -- `block.new_lines`, not the raw arg: the substring fallback produces full modified lines.
        for j = #block.new_lines, 1, -1 do
            table.insert(modified_lines, block.start_line, block.new_lines[j])
        end
    end

    return modified_lines
end

--- Avoids E95 (buffer name already in use).
--- @param suggestion_name string
local function cleanup_stale_suggestion_buf(suggestion_name)
    local existing = vim.fn.bufnr(suggestion_name)
    if existing == -1 then
        return
    end

    for _, winid in ipairs(vim.fn.win_findbuf(existing)) do
        pcall(vim.api.nvim_win_close, winid, true)
    end

    pcall(vim.api.nvim_buf_delete, existing, { force = true })
end

--- @param abs_path string
--- @param bufnr number
--- @param target_winid number
--- @param modified_lines string[]
--- @param state agentic.ui.DiffState|nil
--- @return boolean success
local function open_split_view(
    abs_path,
    bufnr,
    target_winid,
    modified_lines,
    state
)
    local existing_split = state
        and state.split_state
        and state.split_state[abs_path]
    local is_new_owner = existing_split == nil
    local state_identity = state and tostring(state):gsub("^table: ", "")
        or "unowned"
    local suggestion_name =
        string.format("%s (suggestion %s)", abs_path, state_identity)
    cleanup_stale_suggestion_buf(suggestion_name)

    local scratch_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch_bufnr, suggestion_name)
    vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, modified_lines)

    local ft = vim.bo[bufnr].filetype
    if ft and ft ~= "" then
        vim.bo[scratch_bufnr].filetype = ft
    end

    local new_winid = vim.api.nvim_open_win(scratch_bufnr, false, {
        split = "right",
        win = target_winid,
    })

    vim.api.nvim_win_call(target_winid, function()
        vim.cmd("diffthis")
    end)
    vim.api.nvim_win_call(new_winid, function()
        vim.cmd("diffthis")
    end)

    if vim.b[bufnr]._agentic_prev_modifiable == nil then
        vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
    end
    if vim.b[bufnr]._agentic_prev_modified == nil then
        vim.b[bufnr]._agentic_prev_modified = vim.bo[bufnr].modified
    end
    if is_new_owner then
        local owner_count = vim.b[bufnr]._agentic_diff_split_owner_count or 0
        vim.b[bufnr]._agentic_diff_split_owner_count = owner_count + 1
    end
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = true

    vim.bo[scratch_bufnr].modifiable = false

    vim.schedule(function()
        if not vim.api.nvim_win_is_valid(target_winid) then
            return
        end
        local center_cmd = Config.diff_preview.center_on_navigate_hunks and "zz"
            or ""
        pcall(vim.api.nvim_win_call, target_winid, function()
            vim.cmd("normal! gg]c" .. center_cmd)
        end)
    end)

    if state then
        -- Keyed by path: a second pending edit to a DIFFERENT file must not
        -- overwrite this one's window and scratch buffer handles.
        state.split_state = state.split_state or {}
        state.split_state[abs_path] = {
            original_winid = target_winid,
            original_bufnr = bufnr,
            new_winid = new_winid,
            new_bufnr = scratch_bufnr,
            file_path = abs_path,
        }
    end

    return true
end

--- @param abs_path string
--- @param get_winid fun(bufnr: number): number|nil Called when the buffer is not already visible; must return a window displaying bufnr
--- @param tabpage integer|nil Tab the owning widget is visible in
--- @return number|nil bufnr
--- @return number|nil target_winid
local function resolve_buf_and_win(abs_path, get_winid, tabpage)
    local bufnr = vim.fn.bufnr(abs_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(abs_path)
    end

    -- Tab-scoped: the split opens next to the session's own view of the file.
    local winid = BufHelpers.find_visible_win(bufnr, nil, tabpage)
    local target_winid = winid or get_winid(bufnr)
    if not target_winid then
        Logger.debug("show_split_diff: no valid window found")
        return nil, nil
    end

    -- A `get_winid` callback may return a window without loading the buffer.
    if vim.api.nvim_win_get_buf(target_winid) ~= bufnr then
        local ok, err = pcall(vim.api.nvim_win_set_buf, target_winid, bufnr)
        if not ok then
            Logger.debug("resolve_buf_and_win: failed to set buffer:", err)
            return nil, nil
        end
    end

    return bufnr, target_winid
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_split_diff(opts)
    local old_lines = ToolCallDiff.normalize_to_lines(opts.diff.old)
    local new_lines = ToolCallDiff.normalize_to_lines(opts.diff.new)

    local abs_path = FileSystem.to_absolute_path(opts.file_path)

    -- Nothing to diff (e.g. Write tool initial call with empty content)
    if
        ToolCallDiff.is_empty_lines(old_lines)
        and ToolCallDiff.is_empty_lines(new_lines)
    then
        return false
    end

    -- Full file replacement (Write tool): no old_lines, but the file may exist.
    if ToolCallDiff.is_empty_lines(old_lines) then
        local bufnr_check = vim.fn.bufnr(abs_path)
        local file_exists = (
            bufnr_check ~= -1 and vim.api.nvim_buf_is_loaded(bufnr_check)
        ) or vim.uv.fs_stat(abs_path) ~= nil
        if not file_exists then
            Logger.debug("show_split_diff: new file, fallback to inline mode")
            return false
        end

        local bufnr, target_winid =
            resolve_buf_and_win(abs_path, opts.get_winid, opts.tabpage)
        if not bufnr or not target_winid then
            return false
        end

        return open_split_view(
            abs_path,
            bufnr,
            target_winid,
            new_lines,
            opts.state
        )
    end

    local original_lines, err = FileSystem.read_from_buffer_or_disk(abs_path)
    if not original_lines then
        Logger.notify("Failed to read file: " .. tostring(err))
        return false
    end

    local modified_lines = reconstruct_modified_file(
        original_lines,
        old_lines,
        new_lines,
        opts.diff.all
    )
    if not modified_lines then
        Logger.notify(
            "show_split_diff: could not match diff in file, the agent will most likely fail and retry"
        )
        return false
    end

    local bufnr, target_winid =
        resolve_buf_and_win(abs_path, opts.get_winid, opts.tabpage)
    if not bufnr or not target_winid then
        return false
    end

    return open_split_view(
        abs_path,
        bufnr,
        target_winid,
        modified_lines,
        opts.state
    )
end

--- Any one previewed split, preferring the buffer the cursor already sits in so
--- a widget keymap drives the split the user is looking at.
--- @param diff_state agentic.ui.DiffState
--- @return agentic.ui.DiffSplitView.State|nil state
function M.find_split_state(diff_state)
    local split_states = diff_state.split_state
    if not split_states then
        return nil
    end

    local current_bufnr = vim.api.nvim_get_current_buf()

    --- @type agentic.ui.DiffSplitView.State|nil
    local fallback
    for _, state in pairs(split_states) do
        if
            state.original_bufnr == current_bufnr
            or state.new_bufnr == current_bufnr
        then
            return state
        end
        fallback = fallback or state
    end

    return fallback
end

--- @param state agentic.ui.DiffSplitView.State
local function teardown_split(state)
    -- `is_win_usable`, not bare validity: teardown can run after the user closed the
    -- tab, and on 0.11.x such a handle answers valid while `nvim_win_call` segfaults.
    if BufHelpers.is_win_usable(state.original_winid) then
        vim.api.nvim_win_call(state.original_winid, function()
            vim.cmd("diffoff")
        end)
    end

    if BufHelpers.is_win_usable(state.new_winid) then
        vim.api.nvim_win_call(state.new_winid, function()
            vim.cmd("diffoff")
        end)
        pcall(vim.api.nvim_win_close, state.new_winid, true)
    end

    if vim.api.nvim_buf_is_valid(state.new_bufnr) then
        pcall(vim.api.nvim_buf_delete, state.new_bufnr, { force = true })
    end

    if vim.api.nvim_buf_is_valid(state.original_bufnr) then
        local owner_count =
            vim.b[state.original_bufnr]._agentic_diff_split_owner_count
        if owner_count and owner_count > 1 then
            vim.b[state.original_bufnr]._agentic_diff_split_owner_count = owner_count
                - 1
            return
        end

        vim.b[state.original_bufnr]._agentic_diff_split_owner_count = nil
        local prev_modifiable =
            vim.b[state.original_bufnr]._agentic_prev_modifiable
        local prev_modified = vim.b[state.original_bufnr]._agentic_prev_modified

        if prev_modifiable ~= nil then
            vim.bo[state.original_bufnr].modifiable = prev_modifiable
            vim.b[state.original_bufnr]._agentic_prev_modifiable = nil
        end

        if prev_modified ~= nil then
            vim.bo[state.original_bufnr].modified = prev_modified
            vim.b[state.original_bufnr]._agentic_prev_modified = nil
        end
    end
end

--- @param diff_state agentic.ui.DiffState
--- @param file_path string|nil Path to clear; nil tears down every previewed file
--- @return boolean cleared Whether any split was torn down
function M.clear_split_diff(diff_state, file_path)
    local split_states = diff_state.split_state
    if not split_states then
        return false
    end

    local cleared = false

    if file_path then
        local abs_path = FileSystem.to_absolute_path(file_path)
        local state = split_states[abs_path]
        if state then
            teardown_split(state)
            split_states[abs_path] = nil
            cleared = true
        end
    else
        for path, state in pairs(split_states) do
            teardown_split(state)
            split_states[path] = nil
            cleared = true
        end
    end

    -- Nil rather than an empty table, so `if state.split_state` stays a
    -- meaningful "any split showing?" predicate.
    if next(split_states) == nil then
        diff_state.split_state = nil
    end

    return cleared
end

return M
