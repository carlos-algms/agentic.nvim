local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

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
        "The agent session changed. Reopen settings to make changes.",
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

function ConfigOptionsModal:open()
    local width = math.floor(vim.o.columns * 0.5)
    local height = math.max(#self._callbacks.get_options(), 1)
    local row = math.floor((vim.o.lines - height) / 2)
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
        title = " Agentic Settings ",
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

function ConfigOptionsModal:_render()
    if
        not self._bufnr
        or not self._winid
        or not vim.api.nvim_buf_is_valid(self._bufnr)
        or not vim.api.nvim_win_is_valid(self._winid)
    then
        return
    end

    self._line_option_ids = {}
    --- @type string[]
    local lines = {}

    for line_number, option in ipairs(self._callbacks.get_options()) do
        local rendered_value
        if option.type == "boolean" then
            rendered_value = option.currentValue and "[x]" or "[ ]"
        else
            rendered_value = " " .. get_select_value_name(option)
        end

        lines[#lines + 1] = option.name .. ": " .. rendered_value
        self._line_option_ids[line_number] = option.id
    end

    if #lines == 0 then
        lines[1] = "No settings available"
    end

    vim.bo[self._bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self._bufnr, 0, -1, false, lines)
    vim.bo[self._bufnr].modifiable = false
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
