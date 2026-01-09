local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @class agentic.ui.ChatWidget.HeaderConfig
--- @field title string
--- @field suffix? string
--- @field persistent? string

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderConfig>

--- Options for controlling widget display behavior
--- @class agentic.ui.ChatWidget.ShowOpts
--- @field focus_prompt? boolean

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
        persistent = "<S-Tab>: change mode",
    },
    input = { title = "󰦨 Prompt", persistent = "<C-s>: submit" },
    code = {
        title = "󰪸 Selected Code Snippets",
        persistent = "d: remove block",
    },
    files = {
        title = " Referenced Files",
        persistent = "d: remove file",
    },
    todos = {
        title = " TODO Items",
    },
}

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class agentic.ui.ChatWidget
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field headers agentic.ui.ChatWidget.Headers
--- @field on_submit_input fun(prompt: string) external callback to be called when user submits the input
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @param tab_page_id integer
--- @param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    self = setmetatable({}, self)

    self.headers = vim.deepcopy(WINDOW_HEADERS)
    self.win_nrs = {}

    self.on_submit_input = on_submit_input
    self.tab_page_id = tab_page_id

    self:_initialize()
    self:_bind_events_to_change_headers()

    return self
end

function ChatWidget:is_open()
    local win_id = self.win_nrs.chat
    return win_id and vim.api.nvim_win_is_valid(win_id)
end

--- @param opts? agentic.ui.ChatWidget.ShowOpts Options for showing the widget
function ChatWidget:show(opts)
    local options = opts or {}
    local should_focus = options.focus_prompt == nil and true
        or options.focus_prompt

    if
        not self.win_nrs.chat
        or not vim.api.nvim_win_is_valid(self.win_nrs.chat)
    then
        self.win_nrs.chat = self:_open_win(
            self.buf_nrs.chat,
            false,
            {
                -- Only the top most needs a fixed width, others adapt to available space
                width = self._calculate_width(Config.windows.width),
            },
            "chat",
            {
                winfixheight = false,
                scrolloff = 4, -- Keep 4 lines visible above/below cursor (keeps animation visible)
            }
        )

        self:render_header("chat")
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
        }, "input", {})

        self:render_header("input")
    end

    if
        (
            not self.win_nrs.code
            or not vim.api.nvim_win_is_valid(self.win_nrs.code)
        ) and not BufHelpers.is_buffer_empty(self.buf_nrs.code)
    then
        self.win_nrs.code = self:_open_win(self.buf_nrs.code, false, {
            win = self.win_nrs.chat,
            split = "below",
            height = 15,
        }, "code", {})

        self:render_header("code")
    end

    if
        (
            not self.win_nrs.files
            or not vim.api.nvim_win_is_valid(self.win_nrs.files)
        ) and not BufHelpers.is_buffer_empty(self.buf_nrs.files)
    then
        self.win_nrs.files = self:_open_win(self.buf_nrs.files, false, {
            win = self.win_nrs.input,
            split = "above",
            height = 5,
        }, "files", {})

        self:render_header("files")
    end

    if
        Config.windows.todos.display
        and (not self.win_nrs.todos or not vim.api.nvim_win_is_valid(
            self.win_nrs.todos
        ))
        and not BufHelpers.is_buffer_empty(self.buf_nrs.todos)
    then
        local line_count = vim.api.nvim_buf_line_count(self.buf_nrs.todos)

        -- Add 1 for visual padding to prevent last line cutoff because of the header
        local height = math.min(line_count + 1, Config.windows.todos.max_height)

        self.win_nrs.todos = self:_open_win(self.buf_nrs.todos, false, {
            win = self.win_nrs.chat,
            split = "below",
            height = height,
        }, "todos", {})

        self:render_header("todos")
    end

    if should_focus then
        self:move_cursor_to(
            self.win_nrs.input,
            BufHelpers.start_insert_on_last_char
        )
    end
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    vim.cmd("stopinsert")

    local fallback_winid = self:find_first_non_widget_window()

    if not fallback_winid then
        -- Fallback: create a new left window to avoid closing the last window error
        local created_winid = self:open_left_window()
        if not created_winid then
            Logger.notify(
                "Failed to create fallback window; cannot hide widget safely, run `:tabclose` to close the tab instead.",
                vim.log.levels.ERROR
            )
            return
        end
    end

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

--- Cleans up all buffers content without destroying them
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        BufHelpers.with_modifiable(bufnr, function()
            local ok =
                pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
            if not ok then
                Logger.debug(
                    string.format(
                        "Failed to clear buffer '%s' with id: %d",
                        name,
                        bufnr
                    )
                )
            end
        end)
    end
end

--- Deletes all buffers and removes them from memory
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

    self:close_code_window()
    self:close_files_window()
    self:close_todos_window()

    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:move_cursor_to(self.win_nrs.chat)
end

--- @param winid? integer
--- @param callback? fun()
function ChatWidget:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_set_current_win(winid)
            vim.cmd("normal! G0zb")
            if callback then
                callback()
            end
        end
    end)
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()

    self:_bind_keymaps()

    -- I only want to trigger a full close of the chat widget when closing the chat or the input buffers, the others are auxiliary
    for _, bufnr in ipairs({
        self.buf_nrs.chat,
        self.buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = bufnr,
            callback = function()
                self:hide()
            end,
        })
    end

    vim.b[self.buf_nrs.input].completion = false
end

function ChatWidget:_bind_keymaps()
    local submit = Config.keymaps.prompt.submit

    if type(submit) == "string" then
        submit = { submit }
    end

    for _, key in ipairs(submit) do
        --- @type string|string[]
        local modes = "n"
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        BufHelpers.keymap_set(self.buf_nrs.input, modes, keymap, function()
            self:_submit_input()
        end, {
            desc = "Agentic: Submit prompt",
        })
    end

    local paste_image = Config.keymaps.prompt.paste_image

    if type(paste_image) == "string" then
        paste_image = { paste_image }
    end

    for _, key in ipairs(paste_image) do
        --- @type string|string[]
        local modes = "n"
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        BufHelpers.keymap_set(self.buf_nrs.input, modes, keymap, function()
            vim.schedule(function()
                local Clipboard = require("agentic.ui.clipboard")
                local res = Clipboard.paste_image()

                if res ~= nil then
                    -- call vim.paste directly to avoid coupling to the file list logic
                    vim.paste({ res }, -1)
                end
            end)
        end, {
            desc = "Agentic: Paste image from clipboard",
        })
    end

    local close = Config.keymaps.widget.close

    if type(close) == "string" then
        close = { close }
    end

    for _, key in ipairs(close) do
        --- @type string|string[]
        local modes = "n"
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        for _, bufnr in pairs(self.buf_nrs) do
            BufHelpers.keymap_set(bufnr, modes, keymap, function()
                self:hide()
            end, {
                desc = "Agentic: Close Chat widget",
            })
        end
    end

    -- Add keybindings to chat buffer to jump back to input and start insert mode
    for _, key in ipairs({ "a", "A", "o", "O", "i", "I", "c", "C", "x", "X" }) do
        BufHelpers.keymap_set(self.buf_nrs.chat, "n", key, function()
            self:move_cursor_to(
                self.win_nrs.input,
                BufHelpers.start_insert_on_last_char
            )
        end)
    end
end

--- @return agentic.ui.ChatWidget.BufNrs
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
    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    --- @type agentic.ui.ChatWidget.BufNrs
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

    for key, value in pairs(config) do
        vim.api.nvim_set_option_value(key, value, { buf = bufnr })
    end

    return bufnr
end

--- @param bufnr integer
--- @param enter boolean
--- @param opts vim.api.keyset.win_config
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param win_opts table<string, any>
--- @return integer winid
function ChatWidget:_open_win(bufnr, enter, opts, window_name, win_opts)
    --- @type vim.api.keyset.win_config
    local default_opts = {
        split = "right",
        win = -1,
        noautocmd = true,
        style = "minimal",
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    -- Get per-window config
    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = true,
        linebreak = true,
        winfixbuf = true,
        winfixheight = true,
        -- winhighlight = "Normal:NormalFloat,WinSeparator:FloatBorder",
    }, win_opts or {}, config_win_opts)

    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(name, value, { win = winid })
    end

    return winid
end

--- @param keymaps  agentic.UserConfig.KeymapValue
--- @param mode string
local function find_keymap(keymaps, mode)
    if type(keymaps) == "string" then
        return keymaps
    end

    for _, keymap in ipairs(keymaps) do
        if type(keymap) == "string" and mode == "n" then
            return keymap
        elseif type(keymap) == "table" then
            if keymap.mode == mode then
                return keymap[1]
            end

            if type(keymap.mode) == "table" then
                ---@diagnostic disable-next-line: param-type-mismatch
                for _, m in ipairs(keymap.mode) do
                    if m == mode then
                        return keymap[1]
                    end
                end
            end
        end
    end
end

--- Binds events to change the persistent header texts based on current mode keymaps
--- For the Chat and Input buffers only
--- @private
function ChatWidget:_bind_events_to_change_headers()
    for _, bufnr in ipairs({ self.buf_nrs.chat, self.buf_nrs.input }) do
        vim.api.nvim_create_autocmd("ModeChanged", {
            buffer = bufnr,
            callback = function()
                vim.schedule(function()
                    local mode = vim.fn.mode()
                    local change_mode_key =
                        find_keymap(Config.keymaps.widget.change_mode, mode)

                    if change_mode_key ~= nil then
                        self.headers.chat.persistent =
                            string.format("%s: change mode", change_mode_key)
                    else
                        self.headers.chat.persistent = nil
                    end

                    local submit_key =
                        find_keymap(Config.keymaps.prompt.submit, mode)

                    if submit_key ~= nil then
                        self.headers.input.persistent =
                            string.format("%s: submit", submit_key)
                    else
                        self.headers.input.persistent = nil
                    end

                    self:render_header("chat")
                    self:render_header("input")
                end)
            end,
        })
    end
end

--- Calculate width based on editor dimensions
--- Accepts percentage strings ("30%"), decimals (0.3), or absolute numbers (80)
--- @param size number|string
--- @return integer width
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

--- @param window_name agentic.ui.ChatWidget.PanelNames
function ChatWidget:render_header(window_name)
    local winid = self.win_nrs[window_name]
    if not winid then
        return
    end

    local config = self.headers[window_name]
    if not config then
        return
    end

    local opts = {
        config.title,
    }

    if config.suffix ~= nil then
        table.insert(opts, config.suffix)
    end

    if config.persistent ~= nil then
        table.insert(opts, config.persistent)
    end

    WindowDecoration.render_window_header(winid, opts)
end

function ChatWidget:close_code_window()
    if self.win_nrs.code and vim.api.nvim_win_is_valid(self.win_nrs.code) then
        vim.api.nvim_win_close(self.win_nrs.code, true)
        self.win_nrs.code = nil
    end
end

function ChatWidget:close_files_window()
    if self.win_nrs.files and vim.api.nvim_win_is_valid(self.win_nrs.files) then
        vim.api.nvim_win_close(self.win_nrs.files, true)
        self.win_nrs.files = nil
    end
end

function ChatWidget:close_todos_window()
    if self.win_nrs.todos and vim.api.nvim_win_is_valid(self.win_nrs.todos) then
        vim.api.nvim_win_close(self.win_nrs.todos, true)
        self.win_nrs.todos = nil
    end
end

--- Filetypes that should be excluded when finding fallback windows
local EXCLUDED_FILETYPES = {
    -- File explorers
    ["neo-tree"] = true,
    ["NvimTree"] = true,
    ["oil"] = true,
    -- Neovim special buffers
    ["qf"] = true, -- Quickfix
    ["help"] = true, -- Help buffers
    ["man"] = true, -- Man pages
    ["terminal"] = true, -- Terminal buffers
    -- Plugin special windows
    ["TelescopePrompt"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFileHistory"] = true,
    ["fugitive"] = true,
    ["gitcommit"] = true,
    ["dashboard"] = true,
    ["alpha"] = true, -- Alpha dashboard
    ["starter"] = true, -- Mini.starter
    ["notify"] = true, -- nvim-notify
    ["noice"] = true, -- Noice popup
    ["aerial"] = true, -- Aerial outline
    ["Outline"] = true, -- symbols-outline
    ["trouble"] = true, -- Trouble diagnostics
    ["spectre_panel"] = true, -- nvim-spectre
    ["lazy"] = true, -- Lazy plugin manager
    ["mason"] = true, -- Mason installer
}

--- Finds the first window on the current tabpage that is NOT part of the chat widget
--- @return number|nil winid The first non-widget window ID, or nil if none found
function ChatWidget:find_first_non_widget_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.tab_page_id)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(self.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                return winid
            end
        end
    end

    return nil
end

--- Checks if a buffer belongs to this widget
--- @param bufnr number
--- @return boolean
function ChatWidget:_is_widget_buffer(bufnr)
    for _, widget_bufnr in pairs(self.buf_nrs) do
        if widget_bufnr == bufnr then
            return true
        end
    end
    return false
end

--- Opens a new window on the left side with full height
--- @param bufnr? number The buffer to display in the new window
--- @return number|nil winid The newly created window ID or nil on failure
function ChatWidget:open_left_window(bufnr)
    if bufnr == nil then
        -- Try alternate buffer first, but skip if it's a widget buffer or excluded filetype
        local alt_bufnr = vim.fn.bufnr("#")
        if
            alt_bufnr ~= -1
            and vim.api.nvim_buf_is_valid(alt_bufnr)
            and not self:_is_widget_buffer(alt_bufnr)
        then
            local ft = vim.bo[alt_bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                bufnr = alt_bufnr
            end
        end
    end

    if bufnr == nil then
        -- Fall back to first oldfile that exists in current directory
        local oldfiles = vim.v.oldfiles
        local cwd = vim.fn.getcwd()
        if oldfiles and #oldfiles > 0 then
            for _, filepath in ipairs(oldfiles) do
                -- Check if file exists and is under current working directory
                if
                    vim.startswith(filepath, cwd)
                    and vim.fn.filereadable(filepath) == 1
                then
                    local file_bufnr = vim.fn.bufnr(filepath)
                    if file_bufnr == -1 then
                        file_bufnr = vim.fn.bufadd(filepath)
                    end
                    bufnr = file_bufnr
                    break
                end
            end
        end
    end

    -- Last resort: create new scratch buffer
    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
        split = "left",
        win = -1,
    })

    if not ok then
        Logger.notify(
            "Failed to open window: " .. tostring(winid),
            vim.log.levels.WARN
        )
        return nil
    end

    return winid
end

return ChatWidget
