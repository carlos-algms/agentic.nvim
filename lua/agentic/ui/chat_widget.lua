local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local BufferGuard = require("agentic.ui.buffer_guard")
local ChatNavigation = require("agentic.ui.chat_navigation")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"

--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string
--- @field context? string
--- @field suffix? string

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- Only the axis the current layout controls is stored per `hide`, so both
--- survive a `right -> bottom -> right` rotation.
--- @class agentic.ui.ChatWidget.Size
--- @field width? integer
--- @field height? integer

--- @class agentic.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- @class agentic.ui.ChatWidget.AddFilesToContextOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field files (string|integer)[]

--- @class agentic.ui.ChatWidget.ShowOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean

--- @class agentic.ui.ChatWidget
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field current_position agentic.UserConfig.Windows.Position
--- @field on_submit_input fun(prompt: string): boolean
--- @field _winclosed_augroup? integer
--- @field _closing? boolean True during programmatic window closes
--- @field _avoid_auto_close_cmd fun(self: agentic.ui.ChatWidget, fn: fun())
--- @field _hidden_chat_winid? integer
--- @field _size? agentic.ui.ChatWidget.Size Size to reopen at, refreshed on every `hide`
--- @field session_key? integer Registry key, published by `SessionRegistry.create`
--- @field name_suffixed? boolean Sticky latch owned by `WindowDecoration`: once a second session coexisted, this widget's buffer names keep their " (N)" suffix. Never cleared
--- @field _header_refresh_scheduled boolean
--- @field headers agentic.ui.ChatWidget.Headers Mutated in place by `WindowDecoration.get_headers_state` callers
--- @field session_state? agentic.acp.SessionState Set by SessionManager
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @param on_submit_input fun(prompt: string): boolean
function ChatWidget:new(on_submit_input)
    self = setmetatable({}, self)

    self.win_nrs = {}
    self.current_position = Config.windows.position
    self._header_refresh_scheduled = false
    self.session_state = nil

    self.on_submit_input = on_submit_input

    self:_initialize()
    self:_bind_events_to_change_headers()

    return self
end

--- @return integer|nil tabpage nil when the widget is not visible
function ChatWidget:get_visible_tab_id()
    local winid = self.win_nrs.chat
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return nil
    end

    -- 0.11.5 Linux post-tabclose segfault, see WidgetLayout.close.
    local tab_ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
    if not tab_ok or not vim.api.nvim_tabpage_is_valid(win_tab) then
        return nil
    end

    return win_tab
end

function ChatWidget:is_open()
    return self:get_visible_tab_id() ~= nil
end

--- @return boolean
function ChatWidget:is_cursor_in_widget()
    if not self:is_open() then
        return false
    end

    return self:_is_widget_buffer(vim.api.nvim_get_current_buf())
end

function ChatWidget:_close_hidden_chat_window()
    local winid = self._hidden_chat_winid
    self._hidden_chat_winid = nil
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end
    -- 0.11.5 Linux post-tabclose segfault, see WidgetLayout.close.
    local tab_ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
    if tab_ok and vim.api.nvim_tabpage_is_valid(win_tab) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function ChatWidget:show(opts)
    opts = opts or {}

    self:_close_hidden_chat_window()

    self._size = self._size or self:_inherited_size()

    --- @type agentic.ui.WidgetLayout.Params
    local params = {
        buf_nrs = self.buf_nrs,
        win_nrs = self.win_nrs,
        focus_prompt = opts.focus_prompt,
        position = self.current_position,
        size = self._size,
        with_programmatic_close = function(fn)
            self:_avoid_auto_close_cmd(fn)
        end,
    }

    local visible_tab = self:get_visible_tab_id()
    local chat_winid = self.win_nrs.chat

    -- Render in the tab it already occupies; a bare `show` splits from the
    -- current window and leaves an untracked second copy.
    if
        chat_winid
        and visible_tab
        and visible_tab ~= vim.api.nvim_get_current_tabpage()
    then
        -- The focus hop is scheduled, so it escapes `nvim_win_call` and would drag the cursor across tabpages.
        params.focus_prompt = false

        vim.api.nvim_win_call(chat_winid, function()
            WidgetLayout.open(params)
        end)

        return
    end

    WidgetLayout.open(params)
end

--- Content callbacks fire for background sessions too, where a bare `show`
--- builds a second widget in the tab the user is looking at.
function ChatWidget:rerender()
    if not self:get_visible_tab_id() then
        return
    end

    self:show({ focus_prompt = false })
end

--- Size a never-shown widget starts from: the most recent session's, so
--- switching sessions does not resize the sidebar.
--- @return agentic.ui.ChatWidget.Size|nil
function ChatWidget:_inherited_size()
    local SessionRegistry = require("agentic.session_registry")

    --- @type "height"|"width"
    local axis = self.current_position == "bottom" and "height" or "width"

    for _, session in ipairs(SessionRegistry.list()) do
        local size = session.widget._size
        if size and size[axis] then
            return vim.deepcopy(size)
        end
    end

    return nil
end

--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function ChatWidget:rotate_layout(layouts)
    if not layouts or #layouts == 0 then
        layouts = { "right", "bottom", "left" }
    end

    if #layouts == 1 then
        Logger.notify(
            "Only one layout defined for rotation, it'll always show the same: "
                .. layouts[1],
            vim.log.levels.WARN,
            { title = "Agentic: rotate layout" }
        )
    end

    local current = self.current_position
    local next_layout = layouts[1]

    for i, layout in ipairs(layouts) do
        if layout == current then
            local next_index = i % #layouts + 1
            if layouts[next_index] then
                next_layout = layouts[next_index]
            end
            break
        end
    end

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    -- `hide` remembers the axis the CURRENT layout controls, so the position must still be the old one while it runs.
    self:hide()
    self.current_position = next_layout
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        local tabpage = self:get_visible_tab_id()
        if not tabpage then
            return
        end

        -- Tab-scoped: an unscoped lookup would yank the cursor into another tab.
        local win = BufHelpers.find_visible_win(previous_buf, nil, tabpage)
        if not win then
            return
        end

        vim.api.nvim_set_current_win(win)
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Closes all windows but keeps buffers in memory
--- @param keep_insert boolean|nil Set when a `show` follows immediately
--- @param tabpage integer|nil Placement captured before an async boundary, when `win_nrs.chat` is already gone
function ChatWidget:hide(keep_insert, tabpage)
    if not keep_insert then
        vim.cmd("stopinsert")
    end

    self:_remember_size()

    self:_ensure_fallback_window(tabpage)

    self:_avoid_auto_close_cmd(function()
        WidgetLayout.close(self.win_nrs)
    end)

    -- The chat buffer's only remaining window; ADR 0001's manual folds die with it. Close first, or the winid leaks.
    self:_close_hidden_chat_window()
    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)
end

--- Closing a tab's last window destroys that tab, silently when it is not the current one.
--- @param tabpage integer|nil Placement captured before an async boundary
function ChatWidget:_ensure_fallback_window(tabpage)
    -- Liveness is re-resolved here, never captured: only the tabpage IDENTITY
    -- crosses the boundary.
    if tabpage and not vim.api.nvim_tabpage_is_valid(tabpage) then
        return
    end

    tabpage = tabpage or self:get_visible_tab_id()

    if not tabpage or self:find_first_non_widget_window(tabpage) then
        return
    end

    if not self:open_editor_window() then
        Logger.notify(
            "Failed to create a fallback window; the widget's windows may not close cleanly.",
            vim.log.levels.ERROR
        )
    end
end

--- Must run BEFORE `WidgetLayout.close`, which nils `win_nrs`.
function ChatWidget:_remember_size()
    local winid = self.win_nrs.chat
    if not winid or not self:get_visible_tab_id() then
        return
    end

    self._size = self._size or {}

    if self.current_position == "bottom" then
        self._size.height = vim.api.nvim_win_get_height(winid)
    else
        self._size.width = vim.api.nvim_win_get_width(winid)
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

--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    -- MUST precede `unregister`, which makes this widget's own chat window look like a valid fallback.
    self:_ensure_fallback_window()

    WidgetRegistry.unregister(self)

    if self._winclosed_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self._winclosed_augroup)
        self._winclosed_augroup = nil
    end

    -- Not through `hide`: it would reopen a float over deleted buffers.
    WidgetLayout.close(self.win_nrs)

    self:_close_hidden_chat_window()

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

    if not prompt or not prompt:match("%S") then
        return
    end

    local accepted = self.on_submit_input(prompt)
    if not accepted then
        return
    end

    vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})

    local optional_panels = { "code", "files", "diagnostics" }

    for _, panel in ipairs(optional_panels) do
        BufHelpers.with_modifiable(self.buf_nrs[panel], function(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
        end)
    end

    for _, panel in ipairs(optional_panels) do
        self:close_optional_window(panel)
    end

    self:move_cursor_to(self.win_nrs.chat)
end

--- @param winid integer|nil
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            if Config.settings.move_cursor_to_chat_on_submit then
                vim.api.nvim_set_current_win(winid)
            end

            -- Scroll to the bottom so auto-scroll re-engages.
            vim.api.nvim_win_call(winid, function()
                vim.cmd("normal! G0zb")
            end)

            if callback then
                callback()
            end
        end
    end)
end

function ChatWidget:_initialize()
    self.headers = WindowDecoration.default_headers()

    self.buf_nrs = self:_create_buf_nrs()

    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)

    self:_bind_keymaps()

    BufferGuard.ensure()

    self._closing = false

    -- Per chat bufnr: a shared name would wipe the other widget's autocmd,
    -- since `nvim_create_augroup(name, { clear = true })` reuses the id.
    self._winclosed_augroup = vim.api.nvim_create_augroup(
        "AgenticWinClosed_" .. tostring(self.buf_nrs.chat),
        { clear = true }
    )

    vim.api.nvim_create_autocmd("WinClosed", {
        group = self._winclosed_augroup,
        callback = function(ev)
            if self._closing then
                return
            end
            local closed_winid = tonumber(ev.match)
            if not closed_winid then
                return
            end
            for _, winid in pairs(self.win_nrs) do
                if winid == closed_winid then
                    -- Last point the chat window is measurable; WinClosed fires before removal from the layout.
                    self:_remember_size()
                    -- Placement too: the closed window may be `win_nrs.chat`, the only
                    -- handle `get_visible_tab_id` reads, so by schedule time it answers
                    -- nil and the fallback keeping a widget-only tab alive is skipped.
                    local tabpage = self:get_visible_tab_id()
                    vim.schedule(function()
                        self:hide(nil, tabpage)
                    end)
                    return
                end
            end
        end,
        desc = "Agentic: close widget when user closes a core window",
    })

    WidgetRegistry.register(self)
end

function ChatWidget:_bind_keymaps()
    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        self.buf_nrs.input,
        function()
            self:_submit_input()
        end,
        { desc = "Agentic: Submit prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.paste_image,
        self.buf_nrs.input,
        function()
            vim.schedule(function()
                local Clipboard = require("agentic.ui.clipboard")
                local res = Clipboard.paste_image()

                if res ~= nil then
                    vim.paste({ res }, -1)
                end
            end)
        end,
        { desc = "Agentic: Paste image from clipboard" }
    )

    for _, bufnr in pairs(self.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.close,
            bufnr,
            function()
                self:hide()
            end,
            { desc = "Agentic: Close Chat widget" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_provider,
            bufnr,
            function()
                require("agentic").switch_provider()
            end,
            { desc = "Agentic: Switch provider" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.select_session,
            bufnr,
            function()
                require("agentic").select_session()
            end,
            { desc = "Agentic: Select session" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.next_session,
            bufnr,
            function()
                require("agentic").next_session()
            end,
            { desc = "Agentic: Next session" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.prev_session,
            bufnr,
            function()
                require("agentic").prev_session()
            end,
            { desc = "Agentic: Previous session" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.destroy_session,
            bufnr,
            function()
                require("agentic").destroy_session()
            end,
            { desc = "Agentic: Destroy session" }
        )
    end

    -- Editing keys in a read-only panel jump to the input and start insert.
    for panel_name, bufnr in pairs(self.buf_nrs) do
        if panel_name ~= "input" then
            for _, key in ipairs({
                "a",
                "A",
                "o",
                "O",
                "i",
                "I",
                "c",
                "C",
                "x",
                "X",
            }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    self:move_cursor_to(
                        self.win_nrs.input,
                        BufHelpers.start_insert_on_last_char
                    )
                end)
            end
        end
    end

    ChatNavigation.setup_keymaps(self.buf_nrs.chat)
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = self:_create_new_buf({ filetype = "AgenticChat" }),
        todos = self:_create_new_buf({ filetype = "AgenticTodos" }),
        code = self:_create_new_buf({ filetype = "AgenticCode" }),
        files = self:_create_new_buf({ filetype = "AgenticFiles" }),
        diagnostics = self:_create_new_buf({
            filetype = "AgenticDiagnostics",
        }),
        input = self:_create_new_buf({
            filetype = "AgenticInput",
            modifiable = true,
        }),
    }

    -- The chat buffer's highlighting is managed by MessageWriter.
    for name, bufnr in pairs(buf_nrs) do
        if name ~= "chat" then
            pcall(vim.treesitter.start, bufnr, "markdown")
        end
    end

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
    }, opts)

    for key, value in pairs(config) do
        vim.bo[bufnr][key] = value
    end

    return bufnr
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

--- @param mode string
--- @return string|nil suffix nil for modes with no binding; callers keep the last hint
function ChatWidget._compute_input_suffix(mode)
    local submit_key = find_keymap(Config.keymaps.prompt.submit, mode)
    local change_mode_key = find_keymap(Config.keymaps.widget.change_mode, mode)

    local hints = {}
    if submit_key ~= nil then
        hints[#hints + 1] = string.format("submit: %s", submit_key)
    end
    if change_mode_key ~= nil then
        hints[#hints + 1] = string.format("change mode: %s", change_mode_key)
    end

    if #hints == 0 then
        return nil
    end

    return table.concat(hints, " | ")
end

--- @param mode string
function ChatWidget:_apply_input_suffix(mode)
    local suffix = ChatWidget._compute_input_suffix(mode)
    if suffix == nil then
        return
    end

    self.headers.input.suffix = suffix

    self:render_header("input")
end

function ChatWidget:_bind_events_to_change_headers()
    -- Seeded, or the header shows the hard-coded default keys until the first mode change.
    self:_apply_input_suffix("n")

    for _, bufnr in ipairs({ self.buf_nrs.chat, self.buf_nrs.input }) do
        vim.api.nvim_create_autocmd("ModeChanged", {
            buffer = bufnr,
            callback = function()
                vim.schedule(function()
                    self:_apply_input_suffix(vim.fn.mode())
                end)
            end,
        })
    end
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:render_header(window_name, context)
    local bufnr = self.buf_nrs[window_name]
    if not bufnr then
        return
    end

    WindowDecoration.render_header(
        bufnr,
        window_name,
        context,
        self.session_state
    )
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
function ChatWidget:close_optional_window(panel_name)
    self:_avoid_auto_close_cmd(function()
        WidgetLayout.close_optional_window(
            self.win_nrs,
            panel_name,
            self.current_position
        )
    end)
end

--- Flags the close as programmatic so the WinClosed autocmd ignores it.
--- @param fn fun()
function ChatWidget:_avoid_auto_close_cmd(fn)
    self._closing = true
    local ok, err = pcall(fn)
    self._closing = false
    if not ok then
        Logger.notify(tostring(err), vim.log.levels.ERROR)
    end
end

--- Never eligible as a fallback window.
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
    ["fugitiveblame"] = true,
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

--- Scoped to the widget's own tabpage, and excludes EVERY registered widget
--- buffer so one session cannot eject a buffer into another's panel window.
--- @param tabpage integer|nil Overrides the derived placement, for a caller holding a tabpage captured before an async boundary
--- @return number|nil winid
function ChatWidget:find_first_non_widget_window(tabpage)
    local widget_tab = tabpage or self:get_visible_tab_id()
    if not widget_tab or not vim.api.nvim_tabpage_is_valid(widget_tab) then
        return nil
    end

    local all_windows = vim.api.nvim_tabpage_list_wins(widget_tab)
    local widget_bufnrs = WidgetRegistry.all_bufnrs()

    for _, winid in ipairs(all_windows) do
        local win_config = vim.api.nvim_win_get_config(winid)
        if win_config.relative == "" then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if not widget_bufnrs[bufnr] and not EXCLUDED_FILETYPES[ft] then
                return winid
            end
        end
    end

    return nil
end

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

--- First readable oldfile under the cwd, as a bufnr.
--- @return integer|nil bufnr
local function first_oldfile_bufnr()
    local cwd = vim.fn.getcwd()

    for _, filepath in ipairs(vim.v.oldfiles or {}) do
        if
            vim.startswith(filepath, cwd)
            and vim.fn.filereadable(filepath) == 1
        then
            local bufnr = vim.fn.bufnr(filepath)
            if bufnr == -1 then
                bufnr = vim.fn.bufadd(filepath)
            end
            return bufnr
        end
    end

    return nil
end

--- `topleft`/`botright` splits span the full axis whatever window is current.
--- @type table<string, string>
local SPLIT_CMD_BY_POSITION = {
    left = "botright vsplit",
    bottom = "topleft split",
    right = "topleft vsplit",
}

--- Opens a new editor window on the opposite side of the widget.
--- @param bufnr number|nil The buffer to display in the new window
--- @return number|nil winid
function ChatWidget:open_editor_window(bufnr)
    -- A scratch buffer, not the alternate buffer (`#`), which could be a widget buffer.
    bufnr = bufnr
        or first_oldfile_bufnr()
        or vim.api.nvim_create_buf(false, true)

    local split_cmd = SPLIT_CMD_BY_POSITION[self.current_position]
        or SPLIT_CMD_BY_POSITION.right

    -- Splits in the widget's tabpage without moving the user's focus. The chat handle is
    -- already dead when a `WinClosed` on it reaches here, so any surviving widget
    -- window will do as the anchor.
    local anchor_win = BufHelpers.is_win_usable(self.win_nrs.chat)
            and self.win_nrs.chat
        or nil
    if not anchor_win then
        for _, candidate in pairs(self.win_nrs) do
            if BufHelpers.is_win_usable(candidate) then
                anchor_win = candidate
                break
            end
        end
    end

    if not anchor_win then
        return nil
    end

    --- @type integer|nil
    local winid
    local ok = pcall(function()
        winid = vim.api.nvim_win_call(anchor_win, function()
            vim.cmd(split_cmd)
            local new_win = vim.api.nvim_get_current_win()
            pcall(vim.api.nvim_win_set_buf, new_win, bufnr)
            return new_win
        end)
    end)
    if not ok or not winid then
        Logger.notify("Failed to create editor window", vim.log.levels.WARN)
        return nil
    end

    return winid
end

--- Coalesces bursts of header updates into one render.
function ChatWidget:schedule_header_refresh()
    if self._header_refresh_scheduled or not Config.headers then
        return
    end

    self._header_refresh_scheduled = true

    vim.defer_fn(function()
        self._header_refresh_scheduled = false
        self:_render_dynamic_headers()
    end, 150)
end

--- Chat and input always consume session_state, plus any panel the user configured as a header function.
function ChatWidget:_render_dynamic_headers()
    --- @type table<agentic.ui.ChatWidget.PanelNames, boolean>
    local panels = { chat = true, input = true }

    local headers = Config.headers
    if type(headers) == "table" then
        for panel_name, header_config in pairs(headers) do
            if type(header_config) == "function" then
                panels[panel_name] = true
            end
        end
    end

    for panel_name in pairs(panels) do
        self:render_header(panel_name)
    end
end

return ChatWidget
