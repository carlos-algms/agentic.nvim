local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

local NS_CONFIG_OPTIONS =
    vim.api.nvim_create_namespace("agentic_config_options")

local SELECT_ICON = string.char(0xef, 0x81, 0xb8)

--- @class agentic.ui.ConfigOptionsModal
--- @field _callbacks agentic.ui.ConfigOptionsModal.Callbacks
--- @field _bufnr? integer
--- @field _winid? integer
--- @field _line_option_ids table<integer, string>
--- @field _option_rows integer[] sorted 1-based rows of `name: value` lines
local ConfigOptionsModal = {}
ConfigOptionsModal.__index = ConfigOptionsModal

--- @class agentic.ui.ConfigOptionsModal.Callbacks
--- @field get_options fun(): agentic.acp.AnyConfigOption[]
--- @field is_session_active fun(): boolean
--- @field handle_change fun(config_id: string, value: string|boolean, on_done: fun())
--- @field show_selector fun(option: agentic.acp.ConfigOption, prompt: string, handle_change: fun(value: string)): boolean

local function notify_session_changed()
    Logger.notify(
        "The agent session changed. Reopen options to make changes.",
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
end

--- @param option agentic.acp.ConfigOption
--- @return string value_name
local function get_select_value_name(option)
    for _, value in ipairs(option.options or {}) do
        if value.value == option.currentValue then
            return value.name
        end
    end

    return option.currentValue
end

--- @param options agentic.acp.AnyConfigOption[]
--- @param id string
--- @return agentic.acp.AnyConfigOption|nil option
local function find_option(options, id)
    for _, option in ipairs(options) do
        if option.id == id then
            return option
        end
    end

    return nil
end

--- Build the rendered buffer content for the given options.
--- Each option renders a `name: value` row, an optional description row, and a
--- blank separator between blocks. `line_option_ids` maps the 1-based row of a
--- `name: value` line to its option id; description and separator rows are
--- unmapped. `description_rows` holds 0-based rows carrying a description.
--- @param options agentic.acp.AnyConfigOption[]
--- @return string[] lines
--- @return table<integer, string> line_option_ids
--- @return integer[] description_rows
--- @return integer[] option_rows
local function build_lines(options)
    --- @type string[]
    local lines = {}
    --- @type table<integer, string>
    local line_option_ids = {}
    --- @type integer[]
    local description_rows = {}
    --- @type integer[]
    local option_rows = {}

    local label_width = 0
    for _, option in ipairs(options) do
        label_width = math.max(label_width, #option.name + 1)
    end
    label_width = label_width + 2

    for index, option in ipairs(options) do
        local rendered_value
        if option.type == "boolean" then
            rendered_value = option.currentValue and "[x]" or "[ ]"
        else
            rendered_value = SELECT_ICON .. " " .. get_select_value_name(option)
        end

        local label = option.name .. ":"
        local padding = string.rep(" ", label_width - #label)
        lines[#lines + 1] = label .. padding .. rendered_value
        line_option_ids[#lines] = option.id
        option_rows[#option_rows + 1] = #lines

        if option.description and option.description ~= "" then
            lines[#lines + 1] = option.description
            description_rows[#description_rows + 1] = #lines - 1
        end

        if index < #options then
            lines[#lines + 1] = ""
        end
    end

    if #lines == 0 then
        lines[1] = "No options available"
    end

    return lines, line_option_ids, description_rows, option_rows
end

--- @param callbacks agentic.ui.ConfigOptionsModal.Callbacks
--- @return agentic.ui.ConfigOptionsModal
function ConfigOptionsModal:new(callbacks)
    self = setmetatable({
        _callbacks = callbacks,
        _bufnr = nil,
        _winid = nil,
        _line_option_ids = {},
        _option_rows = {},
    }, self)
    return self
end

function ConfigOptionsModal:open()
    local width = math.floor(vim.o.columns * 0.35)
    local lines = build_lines(self._callbacks.get_options())
    local height = math.max(#lines, 1)
    local row = math.floor(vim.o.lines * 0.25)
    local col = math.floor((vim.o.columns - width) / 2)

    self._bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[self._bufnr].bufhidden = "wipe"

    self._winid = vim.api.nvim_open_win(self._bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Agentic Options ",
        title_pos = "center",
        footer = " <CR> toggle/select · q/<Esc> close ",
        footer_pos = "right",
    })

    for _, key in ipairs({ "q", "<Esc>" }) do
        BufHelpers.keymap_set(self._bufnr, "n", key, function()
            if self._winid and vim.api.nvim_win_is_valid(self._winid) then
                vim.api.nvim_win_close(self._winid, true)
            end
        end)
    end
    BufHelpers.keymap_set(self._bufnr, "n", "<CR>", function()
        self:_activate_current_option()
    end)
    for _, key in ipairs({ "j", "<Down>" }) do
        BufHelpers.keymap_set(self._bufnr, "n", key, function()
            self:_jump_to_option(1)
        end)
    end
    for _, key in ipairs({ "k", "<Up>" }) do
        BufHelpers.keymap_set(self._bufnr, "n", key, function()
            self:_jump_to_option(-1)
        end)
    end

    self:_render()
end

function ConfigOptionsModal:_render()
    if
        not self._bufnr
        or not self._winid
        or not vim.api.nvim_buf_is_valid(self._bufnr)
        or not vim.api.nvim_win_is_valid(self._winid)
    then
        return
    end

    local lines, line_option_ids, description_rows, option_rows =
        build_lines(self._callbacks.get_options())
    self._line_option_ids = line_option_ids
    self._option_rows = option_rows

    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.bo[self._bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(self._bufnr, NS_CONFIG_OPTIONS, 0, -1)
    for _, row in ipairs(description_rows) do
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_CONFIG_OPTIONS, row, 0, {
            end_col = #lines[row + 1],
            hl_group = "Comment",
        })
    end
end

--- Move the cursor to the next/previous `name: value` row, wrapping at the
--- ends. Description and separator rows are skipped. If the cursor sits between
--- option rows, the nearest option row in `direction` is chosen.
--- @param direction integer 1 for down, -1 for up
--- @protected
function ConfigOptionsModal:_jump_to_option(direction)
    if
        not self._winid
        or not vim.api.nvim_win_is_valid(self._winid)
        or #self._option_rows == 0
    then
        return
    end

    local cursor_row = vim.api.nvim_win_get_cursor(self._winid)[1]
    local rows = self._option_rows
    local n = #rows

    local current
    for index, row in ipairs(rows) do
        if row == cursor_row then
            current = index
            break
        end
    end

    local target
    if current then
        target = ((current - 1 + direction + n) % n) + 1
    elseif direction > 0 then
        -- Cursor sits between option rows: pick the first row below it,
        -- wrapping to the top when none remain.
        target = 1
        for index, row in ipairs(rows) do
            if row > cursor_row then
                target = index
                break
            end
        end
    else
        -- Pick the first row above the cursor, wrapping to the bottom.
        target = n
        for index = n, 1, -1 do
            if rows[index] < cursor_row then
                target = index
                break
            end
        end
    end

    pcall(
        vim.api.nvim_win_set_cursor,
        self._winid,
        { self._option_rows[target], 0 }
    )
end

function ConfigOptionsModal:_render_after_applied()
    vim.schedule(function()
        self:_render()
    end)
end

function ConfigOptionsModal:_activate_current_option()
    if
        not self._bufnr
        or not self._winid
        or not vim.api.nvim_buf_is_valid(self._bufnr)
        or not vim.api.nvim_win_is_valid(self._winid)
    then
        return
    end

    local line_number = vim.api.nvim_win_get_cursor(self._winid)[1]
    local option_id = self._line_option_ids[line_number]
    if not option_id then
        return
    end

    if not self._callbacks.is_session_active() then
        notify_session_changed()
        return
    end

    local option = find_option(self._callbacks.get_options(), option_id)
    if not option then
        return
    end

    local on_done = function()
        self:_render_after_applied()
    end

    if option.type == "boolean" then
        self._callbacks.handle_change(
            option.id,
            not option.currentValue,
            on_done
        )
        return
    end

    local shown = self._callbacks.show_selector(
        option,
        "Select " .. option.name .. ":",
        function(value)
            if not self._callbacks.is_session_active() then
                notify_session_changed()
                return
            end

            self._callbacks.handle_change(option.id, value, on_done)
        end
    )

    if not shown then
        Logger.notify(
            "This option has no selectable values.",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
end

return ConfigOptionsModal
