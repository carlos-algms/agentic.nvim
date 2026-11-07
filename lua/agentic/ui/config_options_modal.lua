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

--- Wrap text into rows of at most `max_width` display cells.
--- Virtual lines never wrap on their own, so the caller must pre-wrap them.
--- @param text string
--- @param max_width integer
--- @return string[] rows
local function wrap_text(text, max_width)
    --- @type string[]
    local rows = {}
    local current = ""

    for word in text:gmatch("%S+") do
        if current == "" then
            current = word
        elseif vim.fn.strdisplaywidth(current .. " " .. word) > max_width then
            rows[#rows + 1] = current
            current = word
        else
            current = current .. " " .. word
        end
    end

    if current ~= "" then
        rows[#rows + 1] = current
    end

    if #rows == 0 then
        rows[1] = text
    end

    return rows
end

--- Build the rendered buffer content for the given options.
--- Each option renders exactly one real `name: value` row, so the cursor cannot
--- land on a non-option row. Its description row and the blank separator that
--- follows the block are virtual lines drawn below that row, wrapped to
--- `max_width` because virtual lines are truncated, never wrapped.
--- `line_option_ids` maps the 1-based row of a `name: value` line to its option
--- id. `virt_lines_by_row` maps the 0-based anchor row to its virtual line
--- texts.
--- @param options agentic.acp.AnyConfigOption[]
--- @param max_width integer
--- @return string[] lines
--- @return table<integer, string> line_option_ids
--- @return table<integer, string[]> virt_lines_by_row
local function build_lines(options, max_width)
    --- @type string[]
    local lines = {}
    --- @type table<integer, string>
    local line_option_ids = {}
    --- @type table<integer, string[]>
    local virt_lines_by_row = {}

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

        local virt_lines = {}
        if option.description and option.description ~= "" then
            local description_rows = wrap_text(option.description, max_width)
            for _, description_row in ipairs(description_rows) do
                virt_lines[#virt_lines + 1] = description_row
            end
        end
        if index < #options then
            virt_lines[#virt_lines + 1] = ""
        end
        if #virt_lines > 0 then
            virt_lines_by_row[#lines - 1] = virt_lines
        end
    end

    if #lines == 0 then
        lines[1] = "No options available"
    end

    return lines, line_option_ids, virt_lines_by_row
end

--- @param callbacks agentic.ui.ConfigOptionsModal.Callbacks
--- @return agentic.ui.ConfigOptionsModal
function ConfigOptionsModal:new(callbacks)
    self = setmetatable({
        _callbacks = callbacks,
        _bufnr = nil,
        _winid = nil,
        _line_option_ids = {},
    }, self)
    return self
end

--- @return integer width
function ConfigOptionsModal:_get_width()
    return math.floor(vim.o.columns * 0.35)
end

--- Open the modal window for the current options.
function ConfigOptionsModal:open()
    local width = self:_get_width()
    local lines, _, virt_lines_by_row =
        build_lines(self._callbacks.get_options(), width)
    local virtual_line_count = 0
    for _, texts in pairs(virt_lines_by_row) do
        virtual_line_count = virtual_line_count + #texts
    end
    local height = math.max(#lines + virtual_line_count, 1)
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

    self:_render()
end

--- Rewrite the buffer rows and their virtual lines from the live options.
function ConfigOptionsModal:_render()
    if
        not self._bufnr
        or not self._winid
        or not vim.api.nvim_buf_is_valid(self._bufnr)
        or not vim.api.nvim_win_is_valid(self._winid)
    then
        return
    end

    local lines, line_option_ids, virt_lines_by_row =
        build_lines(self._callbacks.get_options(), self:_get_width())
    self._line_option_ids = line_option_ids

    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.bo[self._bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(self._bufnr, NS_CONFIG_OPTIONS, 0, -1)
    for row, texts in pairs(virt_lines_by_row) do
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_CONFIG_OPTIONS, row, 0, {
            virt_lines = self:_build_virt_lines(texts),
        })
    end
end

--- @param texts string[]
--- @return table[] virt_lines
function ConfigOptionsModal:_build_virt_lines(texts)
    local virt_lines = {}
    for _, text in ipairs(texts) do
        virt_lines[#virt_lines + 1] = { { text, "Comment" } }
    end
    return virt_lines
end

function ConfigOptionsModal:_render_after_applied()
    vim.schedule(function()
        self:_render()
    end)
end

--- Apply <CR> on the option row under the cursor.
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
