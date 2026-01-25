local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local TextMatcher = require("agentic.utils.text_matcher")

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
--- @param original_lines string[] Original file content
--- @param old_lines string[] Old text from agent diff
--- @param new_lines string[] New text from agent diff
--- @param replace_all boolean If true, replace all matches; if false, replace only first match
--- @return string[]|nil modified_lines Full modified file content, or nil if failed
local function reconstruct_modified_file(
    original_lines,
    old_lines,
    new_lines,
    replace_all
)
    if #old_lines == 0 then
        return new_lines
    end

    local modified_lines = vim.deepcopy(original_lines)

    local matches = TextMatcher.find_all_matches(original_lines, old_lines)

    if #matches > 0 then
        if replace_all then
            -- Process all matches in reverse order to maintain line indices
            for i = #matches, 1, -1 do
                local match = matches[i]

                -- Remove old lines
                for j = match.end_line, match.start_line, -1 do
                    table.remove(modified_lines, j)
                end

                -- Insert new lines
                for j = #new_lines, 1, -1 do
                    table.insert(modified_lines, match.start_line, new_lines[j])
                end
            end
        else
            -- Only process first match (original behavior)
            local match = matches[1]

            for i = match.end_line, match.start_line, -1 do
                table.remove(modified_lines, i)
            end

            for i = #new_lines, 1, -1 do
                table.insert(modified_lines, match.start_line, new_lines[i])
            end
        end

        return modified_lines
    else
        Logger.debug(
            "reconstruct_modified_file: couldn't locate old_text, using new_text as-is"
        )
        return new_lines
    end
end

--- @param opts agentic.ui.DiffPreview.ShowOpts
function M.show_split_diff(opts)
    local old_lines = opts.diff.old or {}
    local new_lines = opts.diff.new or {}

    if #old_lines == 0 then
        Logger.debug("show_split_diff: new file, fallback to inline mode")
        return false
    end

    local abs_path = FileSystem.to_absolute_path(opts.file_path)
    local bufnr = vim.fn.bufnr(abs_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufadd(abs_path)
    end

    local winid = vim.fn.bufwinid(bufnr)
    local target_winid = winid ~= -1 and winid or opts.get_winid(bufnr)
    if not target_winid then
        Logger.debug("show_split_diff: no valid window found")
        return false
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
        Logger.notify("Failed to reconstruct modified file")
        return false
    end

    local scratch_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(scratch_bufnr, abs_path .. " (suggestion)")
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

    vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable
    vim.b[bufnr]._agentic_prev_modified = vim.bo[bufnr].modified
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = true

    vim.bo[scratch_bufnr].modifiable = false

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
