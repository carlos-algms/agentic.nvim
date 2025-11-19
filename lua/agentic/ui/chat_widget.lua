local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

---@class agentic.ui.ChatWidget.BufNrs
---@field chat number
---@field todos number
---@field code number
---@field files number
---@field input number

---@class agentic.ui.ChatWidget.WinNrs
---@field chat? number
---@field todos? number
---@field code? number
---@field files? number
---@field input? number

---@class agentic.ui.ChatWidget
---@field tab_page_id integer
---@field buf_nrs agentic.ui.ChatWidget.BufNrs
---@field win_nrs agentic.ui.ChatWidget.WinNrs
---@field is_streaming boolean
---@field on_submit_input fun(prompt: string) external callback to be called when user submits the input
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    local instance = setmetatable({
        win_nrs = {},
    }, ChatWidget)

    instance.on_submit_input = on_submit_input
    instance.tab_page_id = tab_page_id

    instance.buf_nrs = instance:_initialize()

    return instance
end

function ChatWidget:is_open()
    local win_id = self.win_nrs.chat
    return win_id and vim.api.nvim_win_is_valid(win_id)
end

function ChatWidget:show()
    if
        not self.win_nrs.chat
        or not vim.api.nvim_win_is_valid(self.win_nrs.chat)
    then
        self.win_nrs.chat = self:_open_win(self.buf_nrs.chat, false, {}, {
            winfixheight = false,
        })
    end

    if
        not self.win_nrs.input
        or not vim.api.nvim_win_is_valid(self.win_nrs.input)
    then
        self.win_nrs.input = self:_open_win(self.buf_nrs.input, true, {
            win = self.win_nrs.chat,
            split = "below",
            height = Config.windows.input.height,
            fixed = true,
        }, {})
    end

    if
        (
            not self.win_nrs.code
            or not vim.api.nvim_win_is_valid(self.win_nrs.code)
        ) and not self:_is_buffer_empty(self.buf_nrs.code)
    then
        self.win_nrs.code = self:_open_win(self.buf_nrs.code, false, {
            win = self.win_nrs.chat,
            split = "below",
            height = 15,
        }, {})
    end

    if
        (
            not self.win_nrs.files
            or not vim.api.nvim_win_is_valid(self.win_nrs.files)
        ) and not self:_is_buffer_empty(self.buf_nrs.files)
    then
        self.win_nrs.files = self:_open_win(self.buf_nrs.files, false, {
            win = self.win_nrs.input,
            split = "above",
            height = 5,
        }, {})
    end

    self:_move_cursor_to(
        self.win_nrs.input,
        BufHelpers.start_insert_on_last_char
    )
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    vim.cmd("stopinsert")

    for name, winid in pairs(self.win_nrs) do
        self.win_nrs[name] = nil
        local ok = pcall(vim.api.nvim_win_close, winid, true)
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to close window '%s' with id: %d",
                    name,
                    winid
                )
            )
        end
    end
end

--- Cleans up all buffers and windows
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    self:hide()

    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to delete buffer '%s' with id: %d",
                    name,
                    bufnr
                )
            )
        end
    end
end

--- @param selections agentic.Selection[]
function ChatWidget:render_code_selection(selections)
    --- @type string[]
    local text_block = {}

    for _, selection in ipairs(selections) do
        if selection and #selection.lines > 0 then
            table.insert(
                text_block,
                string.format(
                    "```%s %s:%d-%d",
                    selection.file_type,
                    selection.file_path,
                    selection.start_line,
                    selection.end_line
                )
            )

            vim.list_extend(text_block, selection.lines)

            table.insert(text_block, "```")
            table.insert(text_block, "")
        end
    end

    BufHelpers.with_modifiable(self.buf_nrs.code, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text_block)
    end)
end

--- @param selected_files string[]
function ChatWidget:render_selected_files(selected_files)
    local lines = {}

    for _, file in ipairs(selected_files) do
        table.insert(lines, "-  " .. FileSystem.to_smart_path(file))
    end

    BufHelpers.with_modifiable(self.buf_nrs.files, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
end

function ChatWidget:_submit_input()
    vim.cmd("stopinsert")

    local lines = vim.api.nvim_buf_get_lines(self.buf_nrs.input, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")

    -- Check if prompt is empty or contains only whitespace
    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})

    BufHelpers.with_modifiable(self.buf_nrs.code, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.files, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.todos, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    self.on_submit_input(prompt)

    if self.win_nrs.code and vim.api.nvim_win_is_valid(self.win_nrs.code) then
        vim.api.nvim_win_close(self.win_nrs.code, true)
        self.win_nrs.code = nil
    end
    if self.win_nrs.files and vim.api.nvim_win_is_valid(self.win_nrs.files) then
        vim.api.nvim_win_close(self.win_nrs.files, true)
        self.win_nrs.files = nil
    end

    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:_move_cursor_to(self.win_nrs.chat)
end

---@param winid? integer
---@param callback? fun()
function ChatWidget:_move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_set_current_win(winid)
            if callback then
                callback()
            end
        end
    end)
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_initialize()
    local buf_nrs = self:_create_buf_nrs()

    BufHelpers.keymap_set(buf_nrs.input, { "n", "i", "v" }, "<C-s>", function()
        self:_submit_input()
    end)

    for _, bufnr in pairs(buf_nrs) do
        BufHelpers.keymap_set(bufnr, "n", "q", function()
            self:hide()
        end)
    end

    BufHelpers.keymap_set(buf_nrs.chat, "n", "q", function()
        self:hide()
    end)

    -- Add keybindings to chat buffer to jump back to input and start insert mode
    for _, key in ipairs({ "a", "A", "o", "O", "i", "I", "c", "C" }) do
        BufHelpers.keymap_set(buf_nrs.chat, "n", key, function()
            self:_move_cursor_to(
                self.win_nrs.input,
                BufHelpers.start_insert_on_last_char
            )
        end)
    end

    -- I only want to trigger a full close of the chat widget when closing the chat or the input buffers, the others are auxiliary
    for _, bufnr in ipairs({
        buf_nrs.chat,
        buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = bufnr,
            callback = function()
                self:hide()
            end,
        })
    end

    vim.api.nvim_buf_call(buf_nrs.input, function()
        -- https://cmp.saghen.dev/recipes#disable-per-filetype-buffer
        vim.b.completion = false
    end)

    return buf_nrs
end

---@param bufnr integer
---@return boolean
function ChatWidget:_is_buffer_empty(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if #lines == 0 then
        return true
    end

    -- Check if buffer contains only whitespace or a single empty line
    if #lines == 1 and lines[1]:match("^%s*$") then
        return true
    end

    -- Check if all lines are whitespace
    for _, line in ipairs(lines) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

---@return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    local chat = self:_create_new_buf({
        filetype = "AgenticChat",
    })

    local todos = self:_create_new_buf({
        filetype = "AgenticTodos",
    })

    local code = self:_create_new_buf({
        filetype = "AgenticCode",
    })

    local files = self:_create_new_buf({
        filetype = "AgenticFiles",
    })

    local input = self:_create_new_buf({
        filetype = "AgenticInput",
        modifiable = true,
    })

    -- Don't call it for the chat buffer as its managed somewhere else
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    ---@type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        input = input,
    }

    return buf_nrs
end

--- @param opts table<string, any>
--- @return integer bufnr
function ChatWidget:_create_new_buf(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)

    local config = vim.tbl_deep_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        buflisted = false,
        modifiable = false,
        syntax = "markdown",
    }, opts)

    for name, value in pairs(config) do
        vim.api.nvim_set_option_value(name, value, { buf = bufnr })
    end
    return bufnr
end

--- @param bufnr integer
--- @param enter boolean
--- @param opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @return integer winid
function ChatWidget:_open_win(bufnr, enter, opts, win_opts)
    ---@type vim.api.keyset.win_config
    local default_opts = {
        split = "right",
        win = -1,
        noautocmd = true,
        style = "minimal",
        width = self._calculate_width(Config.windows.width),
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = true,
        winfixbuf = true,
        winfixheight = true,
    }, win_opts or {})

    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(name, value, { win = winid })
    end

    return winid
end

--- Calculate width based on editor dimensions
--- Accepts percentage strings ("30%"), decimals (0.3), or absolute numbers (80)
---@param size number|string
---@return integer width
function ChatWidget._calculate_width(size)
    local editor_width = vim.o.columns

    -- Parse percentage string (e.g., "40%")
    local is_percentage = type(size) == "string" and string.sub(size, -1) == "%"
    local value

    if is_percentage then
        value = tonumber(string.sub(size, 1, #size - 1)) / 100
    else
        value = tonumber(size)
        is_percentage = (value and value > 0 and value < 1) or false
    end

    if not value then
        is_percentage = true
        value = 0.4
    end

    if is_percentage then
        return math.floor(editor_width * value)
    end

    return value
end

return ChatWidget
