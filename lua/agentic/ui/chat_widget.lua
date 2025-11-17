local Layout = require("nui.layout")
local Split = require("nui.split")
local event = require("nui.utils.autocmd").event

local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")

---@class agentic.ui.ChatWidgetPanels
---@field layout NuiLayout
---@field chat NuiSplit
---@field files NuiSplit
---@field code NuiSplit
---@field todos NuiSplit
---@field input NuiSplit

---@class agentic.ui.ChatWidgetMainBuffer
---@field bufnr? integer
---@field winid? integer
---@field selection? table

---@class agentic.ui.ChatWidget
---@field tab_page_id integer
---@field main_buffer agentic.ui.ChatWidgetMainBuffer The buffer where the chat widget was opened from and will display the active file
---@field panels agentic.ui.ChatWidgetPanels
---@field is_generating boolean
---@field on_submit_input fun(prompt: string) external callback to be called when user submits the input
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    local instance = setmetatable({}, ChatWidget)

    instance.on_submit_input = on_submit_input
    instance.tab_page_id = tab_page_id
    instance.main_buffer = {
        bufnr = vim.api.nvim_get_current_buf(),
        winid = vim.api.nvim_get_current_win(),
        selection = nil,
    }

    instance.panels = instance:_initialize()

    return instance
end

function ChatWidget:is_open()
    local win_id = self.panels.chat and self.panels.chat.winid

    if not win_id then
        return false
    end

    return vim.api.nvim_win_is_valid(win_id)
end

function ChatWidget:show()
    local boxes = self:_get_layout_boxes()
    self.panels.layout:update(nil, boxes)

    if not self:is_open() then
        self.panels.layout:show()
    end

    self:_move_cursor_to(
        self.panels.input.winid,
        BufHelpers.start_insert_on_last_char
    )
end

function ChatWidget:hide()
    if self:is_open() then
        vim.cmd("stopinsert")
        self.panels.layout:hide()
    end
end

function ChatWidget:destroy()
    self.panels.layout:unmount()
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

    local bufnr = self.panels.code.bufnr

    BufHelpers.with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text_block)
    end)
end

--- @param selected_files string[]
function ChatWidget:render_selected_files(selected_files)
    local lines = {}

    for _, file in ipairs(selected_files) do
        table.insert(lines, "-  " .. FileSystem.to_smart_path(file))
    end

    local bufnr = self.panels.files.bufnr

    BufHelpers.with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
end

function ChatWidget:_submit_input()
    local lines =
        vim.api.nvim_buf_get_lines(self.panels.input.bufnr, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")

    -- Check if prompt is empty or contains only whitespace
    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    vim.api.nvim_buf_set_lines(self.panels.input.bufnr, 0, -1, false, {})

    BufHelpers.with_modifiable(self.panels.code.bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.panels.files.bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.panels.todos.bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    vim.cmd("stopinsert")
    self.on_submit_input(prompt)

    local new_boxes = self:_get_layout_boxes()
    self.panels.layout:update(nil, new_boxes)

    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:_move_cursor_to(self.panels.chat.winid)
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

---@return agentic.ui.ChatWidgetPanels
function ChatWidget:_initialize()
    local panels = self:_create_panels()

    self:_setup_cursor_line_toggle(panels.chat)
    self:_setup_cursor_line_toggle(panels.code)
    self:_setup_cursor_line_toggle(panels.files)
    self:_setup_cursor_line_toggle(panels.todos)
    self:_setup_cursor_line_toggle(panels.input)

    panels.input:map("n", "<C-s>", function()
        self:_submit_input()
    end)

    panels.input:map("i", "<C-s>", function()
        self:_submit_input()
    end)

    panels.input:map("n", "q", function()
        self:hide()
    end)

    panels.chat:map("n", "q", function()
        self:hide()
    end)

    -- Add keybindings to chat buffer to jump back to input and start insert mode
    for _, key in ipairs({ "a", "A", "o", "O", "i", "I", "c", "C" }) do
        panels.chat:map("n", key, function()
            self:_move_cursor_to(
                self.panels.input.winid,
                BufHelpers.start_insert_on_last_char
            )
        end)
    end

    return panels
end

---@return agentic.ui.ChatWidgetPanels
function ChatWidget:_create_panels()
    local chat = self._make_split({
        buf_options = {
            filetype = "AgenticChat",
        },
    })

    local todos = self._make_split({
        buf_options = {
            filetype = "AgenticTodos",
        },
    })

    local code = self._make_split({
        buf_options = {
            filetype = "AgenticCode",
        },
    })

    local files = self._make_split({
        buf_options = {
            filetype = "AgenticFiles",
        },
    })

    local input = self._make_split({
        buf_options = {
            filetype = "AgenticInput",
            modifiable = true,
        },
    })

    pcall(vim.treesitter.start, code.bufnr, "markdown")
    pcall(vim.treesitter.start, files.bufnr, "markdown")
    pcall(vim.treesitter.start, input.bufnr, "markdown")

    local layout = Layout(
        {
            position = "right",
            relative = "editor",
            size = Config.windows.width,
        },
        Layout.Box({
            Layout.Box(chat, { grow = 1 }),
        }, { dir = "col" })
    )

    ---@type agentic.ui.ChatWidgetPanels
    local panels = {
        layout = layout,
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        input = input,
    }

    return panels
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

---@return NuiLayout.Box[]
function ChatWidget:_get_layout_boxes()
    ---@type NuiLayout.Box[]
    local boxes = {}

    table.insert(boxes, Layout.Box(self.panels.chat, { grow = 1 }))

    if not self:_is_buffer_empty(self.panels.code.bufnr) then
        table.insert(boxes, Layout.Box(self.panels.code, { size = 10 }))
    end

    if not self:_is_buffer_empty(self.panels.files.bufnr) then
        table.insert(boxes, Layout.Box(self.panels.files, { size = 5 }))
    end

    table.insert(
        boxes,
        Layout.Box(self.panels.input, { size = Config.windows.input.height })
    )

    return Layout.Box(boxes, { dir = "col" })
end

---@param split NuiSplit
function ChatWidget:_setup_cursor_line_toggle(split)
    local cursorline_state = nil

    -- Save initial cursorline state and restore on enter
    split:on(event.BufEnter, function()
        local winid = split.winid
        if winid and vim.api.nvim_win_is_valid(winid) then
            if cursorline_state == nil then
                cursorline_state = vim.wo[winid].cursorline
            else
                vim.api.nvim_set_option_value(
                    "cursorline",
                    cursorline_state,
                    { win = winid }
                )
            end
        end
    end)

    -- Hide cursorline when leaving buffer
    split:on(event.BufLeave, function()
        local winid = split.winid
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_set_option_value("cursorline", false, { win = winid })
        end
    end)
end

---@param props nui_split_options
function ChatWidget._make_split(props)
    return Split(vim.tbl_deep_extend("force", {
        buf_options = {
            swapfile = false,
            buftype = "nofile",
            bufhidden = "hide",
            buflisted = false,
            modifiable = false,
            syntax = "markdown",
        },
        win_options = {
            wrap = true,
            signcolumn = "no",
            number = false,
            relativenumber = false,
            winfixbuf = true,
        },
    }, props))
end

return ChatWidget
