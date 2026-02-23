local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local ToolCallDiff = require("agentic.ui.tool_call_diff")

--- Handles side-by-side diff view using Neovim's native :diffthis command
--- @class agentic.ui.DiffSplitView
local M = {}

--- State for split diff view per tabpage
--- @class agentic.ui.DiffSplitView.State
--- @field original_winid number Window ID of original file buffer
--- @field original_bufnr number Buffer number of original file
--- @field new_winid number Window ID of scratch buffer window
--- @field new_bufnr number Buffer number of scratch buffer
--- @field file_path string Path to file being diffed

--- Get split state from tabpage
--- @param tabpage number Tabpage ID
--- @return agentic.ui.DiffSplitView.State|nil state
local function get_state(tabpage)
    return vim.t[tabpage]._agentic_diff_split_state
end

--- Set split state for tabpage
--- @param tabpage number Tabpage ID
--- @param state agentic.ui.DiffSplitView.State|nil State to set (nil to clear)
local function set_state(tabpage, state)
    vim.t[tabpage]._agentic_diff_split_state = state
end

--- Reconstruct full modified file from agent's partial diffs
--- Uses ToolCallDiff.match_or_substring_fallback for matching, which includes
--- fuzzy matching and single-line substring replacement fallback.
--- @param original_lines string[] Original file content
--- @param old_lines string[] Old text from agent diff
--- @param new_lines string[] New text from agent diff
--- @param replace_all boolean|nil If true, replace all matches; if false, replace only first match
--- @return string[]|nil modified_lines Full modified file content, or nil if failed
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

    -- Process blocks in reverse order to maintain line indices
    for i = #blocks, 1, -1 do
        local block = blocks[i]

        -- Remove old lines
        for j = block.end_line, block.start_line, -1 do
            table.remove(modified_lines, j)
        end

        -- Insert new lines (use block.new_lines, not raw new_lines —
        -- substring fallback produces full modified lines)
        for j = #block.new_lines, 1, -1 do
            table.insert(modified_lines, block.start_line, block.new_lines[j])
        end
    end

    return modified_lines
end

--- Clean up any existing suggestion buffer for the given path to avoid E95
--- @param suggestion_name string
local function cleanup_stale_suggestion_buf(suggestion_name)
    local existing = vim.fn.bufnr(suggestion_name)
    if existing == -1 then
        return
    end

    -- Close any windows displaying the stale buffer
    for _, winid in ipairs(vim.fn.win_findbuf(existing)) do
        pcall(vim.api.nvim_win_close, winid, true)
    end

    pcall(vim.api.nvim_buf_delete, existing, { force = true })
end

--- Open split diff view with original and modified content
--- @param abs_path string
--- @param bufnr number
--- @param target_winid number
--- @param modified_lines string[]
--- @return boolean success
local function open_split_view(abs_path, bufnr, target_winid, modified_lines)
    local suggestion_name = abs_path .. " (suggestion)"
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

    local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, target_winid)
    if not ok then
        return false
    end

    set_state(tabpage, {
        original_winid = target_winid,
        original_bufnr = bufnr,
        new_winid = new_winid,
        new_bufnr = scratch_bufnr,
        file_path = abs_path,
    })

    return true
end

--- Resolve buffer and target window for a file path.
--- get_winid is called when the buffer is not already visible in any window.
--- It must return a window that is displaying bufnr (i.e. call
--- nvim_win_set_buf before returning), as open_split_view runs :diffthis
--- on the returned window. See session_manager.lua get_winid for reference.
--- @param abs_path string
--- @param get_winid fun(bufnr: number): number|nil
--- @return number|nil bufnr
--- @return number|nil target_winid
local function resolve_buf_and_win(abs_path, get_winid)
    local bufnr = vim.fn.bufnr(abs_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(abs_path)
    end

    local winid = vim.fn.bufwinid(bufnr)
    local target_winid = winid ~= -1 and winid or get_winid(bufnr)
    if not target_winid then
        Logger.debug("show_split_diff: no valid window found")
        return nil, nil
    end

    -- Ensure the target window actually displays the buffer (get_winid
    -- callbacks may return a window without loading the buffer into it)
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

    -- Full file replacement (Write tool): old_lines is empty but file may exist on disk
    if ToolCallDiff.is_empty_lines(old_lines) then
        local bufnr_check = vim.fn.bufnr(abs_path)
        local file_exists = (
            bufnr_check ~= -1 and vim.api.nvim_buf_is_loaded(bufnr_check)
        ) or vim.uv.fs_stat(abs_path) ~= nil
        if not file_exists then
            -- Truly new file, fallback to inline mode
            Logger.debug("show_split_diff: new file, fallback to inline mode")
            return false
        end

        local bufnr, target_winid =
            resolve_buf_and_win(abs_path, opts.get_winid)
        if not bufnr or not target_winid then
            return false
        end

        return open_split_view(abs_path, bufnr, target_winid, new_lines)
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

    local bufnr, target_winid = resolve_buf_and_win(abs_path, opts.get_winid)
    if not bufnr or not target_winid then
        return false
    end

    return open_split_view(abs_path, bufnr, target_winid, modified_lines)
end

--- @param tabpage number|nil Tabpage ID (defaults to current tabpage)
--- @return agentic.ui.DiffSplitView.State|nil state
function M.get_split_state(tabpage)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()
    return get_state(tab)
end

--- @param tabpage number|nil Tabpage ID (defaults to current tabpage)
function M.clear_split_diff(tabpage)
    local tab = tabpage or vim.api.nvim_get_current_tabpage()
    local state = get_state(tab)

    if not state then
        return
    end

    if vim.api.nvim_win_is_valid(state.original_winid) then
        vim.api.nvim_win_call(state.original_winid, function()
            vim.cmd("diffoff")
        end)
    end

    if vim.api.nvim_win_is_valid(state.new_winid) then
        vim.api.nvim_win_call(state.new_winid, function()
            vim.cmd("diffoff")
        end)
        pcall(vim.api.nvim_win_close, state.new_winid, true)
    end

    if vim.api.nvim_buf_is_valid(state.new_bufnr) then
        pcall(vim.api.nvim_buf_delete, state.new_bufnr, { force = true })
    end

    if vim.api.nvim_buf_is_valid(state.original_bufnr) then
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

    set_state(tab, nil)
end

return M
