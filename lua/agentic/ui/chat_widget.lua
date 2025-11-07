local Layout = require("nui.layout")
local Split = require("nui.split")
local event = require("nui.utils.autocmd").event

---@class agentic.ui.ChatWidgetWinIds
---@field result_container integer
---@field todos_container integer integer
---@field selected_files_container integer
---@field selected_code_container integer
---@field input_container integer

---@class agentic.ui.ChatWidgetPanels
---@field input? NuiSplit
---@field chat? NuiSplit
---@field todos? NuiSplit
---@field files? NuiSplit
---@field code? NuiSplit
---@field layout? NuiLayout

---@class agentic.ui.ChatWidgetMainBuffer
---@field bufnr? integer
---@field winid? integer
---@field selection? table

---@class agentic.ui.ChatWidget
---@field was_mounted boolean
---@field tab_page_id integer
---@field main_buffer agentic.ui.ChatWidgetMainBuffer The buffer where the chat widget was opened from and will display the active file
---@field win_ids agentic.ui.ChatWidgetWinIds
---@field panels agentic.ui.ChatWidgetPanels
---@field is_generating boolean
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
function ChatWidget:new(tab_page_id)
    local instance = setmetatable({}, ChatWidget)
    instance.tab_page_id = tab_page_id
    instance.main_buffer = {
        bufnr = 0,
        winid = 0,
        selection = nil,
    }
    instance.panels = {}

    instance:_initialize()

    return instance
end

function ChatWidget:is_open()
    local win_id = self.panels.chat and self.panels.chat.winid

    if not win_id then
        return false
    end

    return vim.api.nvim_win_is_valid(win_id)
end

function ChatWidget:open()
    if not self:is_open() then
        self.panels.layout:show()
    end
end

function ChatWidget:hide()
    if self:is_open() then
        self.panels.layout:hide()
    end
end

function ChatWidget:toggle()
    if self:is_open() then
        self:hide()
    else
        self:open()
    end
end

function ChatWidget:_initialize()
    self.main_buffer.winid = vim.api.nvim_get_current_win()
    self.main_buffer.bufnr = vim.api.nvim_get_current_buf()

    --FIXIT: deduplicate the split properties

    self.panels.chat = Split({
        buf_options = {
            swapfile = false,
            buftype = "nofile",
            filetype = "AgenticChat",
        },
        win_options = {
            wrap = true,
            signcolumn = "no",
            number = false,
            relativenumber = false,
        },
    })

    self.panels.files = Split({
        buf_options = {
            swapfile = false,
            buftype = "nofile",
            filetype = "AgenticBlock2",
        },
        win_options = {
            wrap = true,
            signcolumn = "no",
            number = false,
            relativenumber = false,
        },
    })

    self.panels.input = Split({
        buf_options = {
            swapfile = false,
            buftype = "nofile",
            filetype = "AgenticBlock3",
        },
        win_options = {
            wrap = true,
            signcolumn = "no",
            number = false,
            relativenumber = false,
        },
    })

    -- Only start in insert mode the first time the input panel is opened
    self.panels.input:on(event.BufEnter, function()
        self.panels.input:off(event.BufEnter)
        vim.cmd("startinsert!")
    end)

    self.panels.layout = Layout(
        {
            position = "right",
            relative = "editor",
            size = "40%",
        },
        Layout.Box({
            Layout.Box(self.panels.chat, { grow = 1 }),
            Layout.Box(self.panels.files, { size = 10 }),
            Layout.Box(self.panels.input, { size = 15 }),
        }, { dir = "col" })
    )
end

return ChatWidget
