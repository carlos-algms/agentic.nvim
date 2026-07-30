local Config = require("agentic.config")
local DiagnosticsContext = require("agentic.ui.diagnostics_context")
local WidgetLayout = require("agentic.ui.widget_layout")
local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")

--- @return table<number, string> icons Keyed by `vim.diagnostic.severity`
local function get_diagnostic_icons()
    local icons = Config.diagnostic_icons
    return {
        [vim.diagnostic.severity.ERROR] = icons.error,
        [vim.diagnostic.severity.WARN] = icons.warn,
        [vim.diagnostic.severity.INFO] = icons.info,
        [vim.diagnostic.severity.HINT] = icons.hint,
    }
end

--- @class agentic.ui.DiagnosticsList.Diagnostic : vim.Diagnostic
--- @field file_path string

--- @class agentic.ui.DiagnosticsList
--- @field _diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @field _bufnr integer The ChatWidget's diagnostics buffer
--- @field _on_change fun(diagnosticsList: agentic.ui.DiagnosticsList)
local DiagnosticsList = {}
DiagnosticsList.__index = DiagnosticsList

--- @param bufnr integer The diagnostics buffer number from ChatWidget
--- @param on_change fun(diagnosticsList: agentic.ui.DiagnosticsList)
--- @return agentic.ui.DiagnosticsList
function DiagnosticsList:new(bufnr, on_change)
    local instance = setmetatable({
        _diagnostics = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings()

    return instance
end

--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic|nil
--- @return boolean success false when absent or already present
function DiagnosticsList:_add_no_render(diagnostic)
    if not diagnostic or not diagnostic.bufnr then
        return false
    end

    local file_path = type(diagnostic.file_path) == "string"
            and diagnostic.file_path
        or ""

    if file_path == "" and vim.api.nvim_buf_is_valid(diagnostic.bufnr) then
        file_path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    end

    diagnostic.file_path = file_path

    for _, existing in ipairs(self._diagnostics) do
        if
            existing.bufnr == diagnostic.bufnr
            and existing.lnum == diagnostic.lnum
            and existing.col == diagnostic.col
            and existing.message == diagnostic.message
            and existing.severity == diagnostic.severity
            and existing.source == diagnostic.source
            and existing.code == diagnostic.code
        then
            return false
        end
    end

    self._diagnostics[#self._diagnostics + 1] = diagnostic
    return true
end

--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic|nil
--- @return boolean success
function DiagnosticsList:add(diagnostic)
    if not self:_add_no_render(diagnostic) then
        return false
    end

    self:_render()
    return true
end

--- @param diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @return integer count
function DiagnosticsList:add_many(diagnostics)
    local count = 0
    for _, diagnostic in ipairs(diagnostics) do
        if self:_add_no_render(diagnostic) then
            count = count + 1
        end
    end

    if count > 0 then
        self:_render()
    end

    return count
end

--- @param index integer
function DiagnosticsList:remove_at(index)
    if index < 1 or index > #self._diagnostics then
        return
    end

    table.remove(self._diagnostics, index)
    self:_render()
end

--- @return agentic.ui.DiagnosticsList.Diagnostic[]
function DiagnosticsList:get_diagnostics()
    return vim.deepcopy(self._diagnostics)
end

--- @param chat_width integer The width to format diagnostics against
--- @return string[] lines the lines to be written on the chat
--- @return agentic.acp.Content[] prompt the content to be sent in the prompt to the agent
function DiagnosticsList:to_prompt(chat_width)
    --- @type string[]
    local lines = {}
    --- @type agentic.acp.Content[]
    local prompt = {}

    lines[#lines + 1] = "\n- **Diagnostics**:"

    local diagnostics = self:get_diagnostics()
    self:clear()

    local formatted_diagnostics =
        DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

    for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
        prompt[#prompt + 1] = prompt_entry
    end

    for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
        lines[#lines + 1] = summary_line
    end

    return lines, prompt
end

function DiagnosticsList:clear()
    self._diagnostics = {}
    self:_render()
end

--- @return boolean
function DiagnosticsList:is_empty()
    return #self._diagnostics == 0
end

--- Stamps each diagnostic with the buffer's path.
--- @param bufnr integer
--- @param opts vim.diagnostic.GetOpts
--- @param keep (fun(d: vim.Diagnostic): boolean)|nil Keeps everything when nil
--- @return agentic.ui.DiagnosticsList.Diagnostic[]
local function collect_diagnostics(bufnr, opts, keep)
    local file_path = vim.api.nvim_buf_get_name(bufnr)

    --- @type agentic.ui.DiagnosticsList.Diagnostic[]
    local diagnostics = {}

    for _, d in ipairs(vim.diagnostic.get(bufnr, opts)) do
        if keep == nil or keep(d) then
            diagnostics[#diagnostics + 1] =
                vim.tbl_extend("force", d, { file_path = file_path }) --[[@as agentic.ui.DiagnosticsList.Diagnostic]]
        end
    end

    return diagnostics
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @param opts vim.diagnostic.GetOpts|nil
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics
function DiagnosticsList.get_buffer_diagnostics(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    return collect_diagnostics(bufnr, opts or {}, nil)
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @param opts vim.diagnostic.GetOpts|nil
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics
function DiagnosticsList.get_diagnostics_at_cursor(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    -- The invoking window is PREFERRED, not a last resort: `win_findbuf` returns tabpage
    -- order regardless of the current tab, so an unpreferred lookup reads another tab's
    -- cursor whenever that tab sorts earlier.
    local winid =
        BufHelpers.find_visible_win(bufnr, vim.api.nvim_get_current_win())
    if not winid then
        return {}
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1] - 1

    return collect_diagnostics(bufnr, opts or {}, function(d)
        return cursor_line >= d.lnum and cursor_line <= (d.end_lnum or d.lnum)
    end)
end

--- @private
function DiagnosticsList:_render()
    local lines = {}
    local icons = get_diagnostic_icons()

    local buf_width = WidgetLayout.calculate_width(Config.windows.width)
    local winid = BufHelpers.find_visible_win(self._bufnr, nil)
    if winid then
        buf_width = vim.api.nvim_win_get_width(winid)
    end

    for _, diagnostic in ipairs(self._diagnostics) do
        local icon = icons[diagnostic.severity]
            or icons[vim.diagnostic.severity.ERROR]
        local smart_path = diagnostic.file_path
        if smart_path == "" then
            smart_path = string.format("[unnamed:%d]", diagnostic.bufnr)
        else
            smart_path = FileSystem.to_smart_path(smart_path)
        end
        local location = string.format(
            "%s:%d:%d",
            smart_path,
            diagnostic.lnum + 1,
            diagnostic.col + 1
        )

        -- `nvim_buf_set_lines` rejects embedded newlines.
        local message = type(diagnostic.message) == "string"
                and diagnostic.message
            or tostring(diagnostic.message or "")
        message = message:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")

        local line = string.format("%s %s - %s", icon, location, message)
        lines[#lines + 1] =
            DiagnosticsContext.truncate_for_display(line, buf_width)
    end

    local did_render = BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return true
    end)

    if did_render then
        self._on_change(self)
    end
end

--- @private
function DiagnosticsList:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "d", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = cursor[1]

        local line_content =
            vim.api.nvim_buf_get_lines(self._bufnr, line - 1, line, false)[1]

        if line_content and line_content:match("%S") then
            self:remove_at(line)
        end
    end, { nowait = true })

    BufHelpers.keymap_set(self._bufnr, "v", "d", function()
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        -- Descending, so each removal leaves the lower indices valid.
        local removed = 0
        for line = math.min(end_line, #self._diagnostics), start_line, -1 do
            local line_content = vim.api.nvim_buf_get_lines(
                self._bufnr,
                line - 1,
                line,
                false
            )[1]

            if line_content and line_content:match("%S") and line >= 1 then
                table.remove(self._diagnostics, line)
                removed = removed + 1
            end
        end

        if removed > 0 then
            self:_render()
        end

        BufHelpers.feed_ESC_key()
    end, { nowait = true })
end

return DiagnosticsList
