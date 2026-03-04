local Config = require("agentic.config")
local DiagnosticsContext = require("agentic.ui.diagnostics_context")
local WidgetLayout = require("agentic.ui.widget_layout")
local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")

--- Get diagnostic severity icons from config
--- @return table<number, string> Mapping of severity to icon
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
--- @field file_path string Full file path

--- @class agentic.ui.DiagnosticsList
--- @field _diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @field _bufnr integer the same buffer number as the ChatWidget's diagnostics buffer
--- @field _on_change fun(diagnosticsList: agentic.ui.DiagnosticsList)
local DiagnosticsList = {}
DiagnosticsList.__index = DiagnosticsList

--- @param bufnr integer The diagnostics buffer number from ChatWidget
--- @param on_change fun(diagnosticsList: agentic.ui.DiagnosticsList) Callback to trigger when diagnostics list changes (e.g., update header)
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

--- Add a diagnostic to the list if not already present
--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic|nil
--- @return boolean success
function DiagnosticsList:_add_no_render(diagnostic)
    if not diagnostic or not diagnostic.bufnr then
        return false
    end

    local file_path = diagnostic.file_path
    if type(file_path) ~= "string" then
        file_path = ""
    end

    if file_path == "" and vim.api.nvim_buf_is_valid(diagnostic.bufnr) then
        file_path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    end

    if type(file_path) ~= "string" then
        file_path = ""
    end
    diagnostic.file_path = file_path

    -- Check for duplicates
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

    table.insert(self._diagnostics, diagnostic)
    return true
end

--- Add a diagnostic to the list if not already present
--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic|nil
--- @return boolean success
function DiagnosticsList:add(diagnostic)
    if not self:_add_no_render(diagnostic) then
        return false
    end

    self:_render()
    return true
end

--- Add multiple diagnostics at once
--- @param diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @return integer count Number of diagnostics added
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

function DiagnosticsList:clear()
    self._diagnostics = {}
    self:_render()
end

--- @return boolean
function DiagnosticsList:is_empty()
    return #self._diagnostics == 0
end

--- Get diagnostics for a specific buffer
--- @param bufnr integer|nil If nil, uses current buffer
--- @param opts vim.diagnostic.GetOpts|nil Options passed to vim.diagnostic.get()
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics Converted diagnostics
function DiagnosticsList.get_buffer_diagnostics(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    --- @type vim.Diagnostic[]
    local vim_diagnostics = vim.diagnostic.get(bufnr, opts)
    local file_path = vim.api.nvim_buf_get_name(bufnr)

    --- @type agentic.ui.DiagnosticsList.Diagnostic[]
    local diagnostics = {}

    for _, d in ipairs(vim_diagnostics) do
        --- @type agentic.ui.DiagnosticsList.Diagnostic
        local diagnostic = vim.tbl_extend("force", d, { file_path = file_path }) --[[@as agentic.ui.DiagnosticsList.Diagnostic]]
        table.insert(diagnostics, diagnostic)
    end

    return diagnostics
end

--- Get diagnostics at the cursor line
--- @param bufnr integer|nil If nil, uses current buffer
--- @param opts vim.diagnostic.GetOpts|nil Options passed to vim.diagnostic.get()
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics Diagnostics at the cursor line
function DiagnosticsList.get_diagnostics_at_cursor(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        local current_winid = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_buf(current_winid) ~= bufnr then
            return {}
        end
        winid = current_winid
    end

    local cursor_pos = vim.api.nvim_win_get_cursor(winid)
    local cursor_line = cursor_pos[1] - 1 -- Convert to 0-indexed

    --- @type vim.Diagnostic[]
    local vim_diagnostics = vim.diagnostic.get(bufnr, opts)
    local file_path = vim.api.nvim_buf_get_name(bufnr)

    --- @type agentic.ui.DiagnosticsList.Diagnostic[]
    local diagnostics = {}

    for _, d in ipairs(vim_diagnostics) do
        local end_lnum = d.end_lnum or d.lnum
        if cursor_line >= d.lnum and cursor_line <= end_lnum then
            --- @type agentic.ui.DiagnosticsList.Diagnostic
            local diagnostic =
                vim.tbl_extend("force", d, { file_path = file_path }) --[[@as agentic.ui.DiagnosticsList.Diagnostic]]
            table.insert(diagnostics, diagnostic)
        end
    end

    return diagnostics
end

--- @private
function DiagnosticsList:_render()
    local lines = {}
    local icons = get_diagnostic_icons()

    local buf_width = WidgetLayout.calculate_width(Config.windows.width)
    local winid = vim.fn.bufwinid(self._bufnr)
    if winid ~= -1 then
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

        -- nvim_buf_set_lines rejects embedded newlines in a line item.
        -- Keep diagnostics single-line by rendering newlines as escaped text.
        local message = type(diagnostic.message) == "string"
                and diagnostic.message
            or tostring(diagnostic.message or "")
        message = message:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")

        -- Format: ICON path:line:col - message
        local line = string.format("%s %s - %s", icon, location, message)
        table.insert(
            lines,
            DiagnosticsContext.truncate_for_display(line, buf_width)
        )
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

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        --- @type table<integer, true>
        local indices_to_remove = {}
        for line = start_line, end_line do
            local line_content = vim.api.nvim_buf_get_lines(
                self._bufnr,
                line - 1,
                line,
                false
            )[1]

            if
                line_content
                and line_content:match("%S")
                and line >= 1
                and line <= #self._diagnostics
            then
                indices_to_remove[line] = true
            end
        end

        --- @type integer[]
        local sorted_indices = {}
        for index in pairs(indices_to_remove) do
            table.insert(sorted_indices, index)
        end
        table.sort(sorted_indices, function(a, b)
            return a > b
        end)

        for _, index in ipairs(sorted_indices) do
            table.remove(self._diagnostics, index)
        end

        if #sorted_indices > 0 then
            self:_render()
        end

        -- Exit visual mode
        BufHelpers.feed_ESC_key()
    end, { nowait = true })
end

return DiagnosticsList
