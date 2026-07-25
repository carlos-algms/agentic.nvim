local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local BufferGuard = require("agentic.ui.buffer_guard")
local ChatNavigation = require("agentic.ui.chat_navigation")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")
local WidgetRegistry = require("agentic.ui.widget_registry")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field suffix? string Context help text

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- Remembered chat window size. Only the axis the layout controls is stored per
--- `hide`, so both survive a `right -> bottom -> right` rotation.
--- @class agentic.ui.ChatWidget.Size
--- @field width? integer
--- @field height? integer

--- Options for controlling widget display behavior
--- @class agentic.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- Options for adding file paths or buffers to the current Chat context
--- @class agentic.ui.ChatWidget.AddFilesToContextOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field files (string|integer)[]

--- Options for showing the widget
--- @class agentic.ui.ChatWidget.ShowOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean Automatically add current selection or file to context when opening

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class agentic.ui.ChatWidget
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field current_position agentic.UserConfig.Windows.Position
--- @field on_submit_input fun(prompt: string): boolean external callback to be called when user submits the input
--- @field _winclosed_augroup? integer WinClosed autocmd group ID
--- @field _closing? boolean True during programmatic window closes
--- @field _avoid_auto_close_cmd fun(self: agentic.ui.ChatWidget, fn: fun())
--- @field _hidden_chat_winid? integer
--- @field _size? agentic.ui.ChatWidget.Size Chat window size to reopen at, refreshed on every `hide`
--- @field session_key? integer Registry key, published by `SessionRegistry.create` so a bufnr can reach it
--- @field _header_refresh_scheduled boolean Guards coalesced header refresh
--- @field headers agentic.ui.ChatWidget.Headers Per-widget header parts, so header context follows the session between tabs. Returned by `WindowDecoration.get_headers_state`, whose callers mutate it in place
--- @field session_state? agentic.acp.SessionState Live session state forwarded to header/buffer_name callbacks; set by SessionManager
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

--- The tabpage the widget is currently visible in, derived from its live chat
--- window. Nothing stores a tabpage.
--- The hidden chat float lives outside `win_nrs`, so it never counts as visible.
--- @return integer|nil tabpage nil when the widget is not visible
function ChatWidget:visible_tab()
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
    return self:visible_tab() ~= nil
end

--- Check if the cursor is currently in one of the widget's buffers
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
    }

    local visible_tab = self:visible_tab()
    local chat_winid = self.win_nrs.chat

    -- Already on screen in another tab: render THERE. `show_layout` splits from
    -- the window current at call time, so without this the widget is rebuilt in
    -- whichever tab the cursor happens to be in and the old tab keeps a second
    -- copy that `win_nrs` no longer tracks and nothing can ever close. Measured:
    -- a background session's content callback produced 4 widget windows.
    -- The prompt is never focused on this path: the focus hop is scheduled, so it
    -- escapes `nvim_win_call` and would drag the cursor into another tabpage.
    -- Moving a session BETWEEN tabs goes through `SessionRegistry.show_session`,
    -- which hides it first, so it never reaches this branch.
    -- Regression: test_multi_session.lua::"renders in its own tab when shown from
    -- another one".
    if
        chat_winid
        and visible_tab
        and visible_tab ~= vim.api.nvim_get_current_tabpage()
    then
        params.focus_prompt = false

        vim.api.nvim_win_call(chat_winid, function()
            WidgetLayout.open(params)
        end)

        return
    end

    WidgetLayout.open(params)
end

--- Re-renders the layout ONLY when the widget is already on screen somewhere.
--- Content callbacks (files, code, diagnostics, todos) fire for BACKGROUND
--- sessions too — a `plan` update needs no user action at all — and a bare `show`
--- would build a SECOND widget in the tab the user is looking at, bypassing
--- `SessionRegistry.show_session`. Measured: four widget windows in one tab, and
--- `Agentic.close` then hid whichever `pairs` reached first and stranded the
--- other.
--- Skipping loses nothing: the panel buffer is written before the callback runs,
--- and `show` opens every panel whose buffer is non-empty, so the content appears
--- when the user opens the session. Same gate as `DiffCoordinator:show`.
--- Regression: test_multi_session.lua::"keeps a hidden session hidden when its
--- file list changes".
function ChatWidget:show_if_visible()
    if not self:visible_tab() then
        return
    end

    self:show({ focus_prompt = false })
end

--- Size the widget starts from when it has never been shown: the most recently
--- visible session's remembered size, so switching sessions does not resize the
--- sidebar. Copied, so two widgets never share one table.
--- Read at `show` time, not at construction: the outgoing widget's `hide` — which
--- refreshes its size — runs between the two.
--- Only a session carrying THIS layout's axis counts: `_remember_size` stores one
--- axis per layout, so a `bottom`-only session holds a height and no width, and
--- stopping at it would drop back to the configured width.
--- Regression: chat_widget.test.lua::"skips a stored size that lacks the axis the
--- new layout needs".
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

    -- `hide` remembers the axis the CURRENT layout controls, so the position
    -- must still be the old one while it runs. Rotating first stored a bottom
    -- height taken from a full-height right-layout chat window.
    self:hide()
    self.current_position = next_layout
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        -- Scoped to this widget's own tab, and nil when the buffer is not on
        -- screen there. The lookup this replaced could only ever see the current
        -- tab; an unscoped one would yank the cursor into another tabpage, and an
        -- unguarded one would land it in the hidden chat float.
        local win =
            BufHelpers.find_visible_win(previous_buf, nil, self:visible_tab())
        if win then
            vim.api.nvim_set_current_win(win)
        end
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Closes all windows but keeps buffers in memory
--- @param keep_insert boolean|nil True when the caller shows a widget right after
--- this hide, so insert mode must survive. `stopinsert` is LATCHED until the
--- current insert command ends, which is after every scheduled callback, so it
--- would beat `show`'s scheduled `startinsert!` no matter how the two are
--- ordered — measured: a session moved between tabs landed in the prompt in
--- normal mode.
--- Regression: test_open_close_widget.lua::"handles tabclose while in insert mode
--- without errors".
function ChatWidget:hide(keep_insert)
    if not keep_insert then
        vim.cmd("stopinsert")
    end

    self:_remember_size()

    self:_ensure_fallback_window()

    self:_avoid_auto_close_cmd(function()
        WidgetLayout.close(self.win_nrs)
    end)

    -- Recreate the float unconditionally, including when no fallback window
    -- could be made: it is the chat buffer's only remaining window, and ADR
    -- 0001's manual folds die with it.
    -- Close prior float before reopen to avoid leaking the winid.
    self:_close_hidden_chat_window()
    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)
end

--- A non-widget window must survive in the widget's OWN tab, whichever tab the
--- cursor sits in: closing the last window of a tab destroys that tab. For a
--- non-current tab it happens silently, so the user loses a tabpage with no
--- error; E444 only fires when it is also the last tabpage.
--- Shared by `hide` and `destroy`: both reach `WidgetLayout.close`, and both are
--- driven from another tab — `SessionRegistry.show_session` evicts a widget it
--- finds elsewhere, and `Agentic.destroy_session` / `SessionRestore` resolve
--- through `SessionRegistry._most_recent`, which is not tab-scoped.
--- `open_editor_window` is cross-tab safe, it splits inside
--- `nvim_win_call(anchor_win, ...)`.
--- No-op once `visible_tab` answers nil, which covers a hidden widget and a
--- tabclose teardown where Neovim already invalidated the windows.
--- Regressions: chat_widget.test.lua::"keeps the tabpage alive when the widget
--- holds its only windows" and ::"creates the fallback window in the widget's tab,
--- not the current one".
function ChatWidget:_ensure_fallback_window()
    if not self:visible_tab() or self:find_first_non_widget_window() then
        return
    end

    if not self:open_editor_window() then
        Logger.notify(
            "Failed to create a fallback window; the widget's windows may not close cleanly.",
            vim.log.levels.ERROR
        )
    end
end

--- Stores the chat window's size along the axis the current layout controls, so a
--- manual resize survives hide/show and seeds the next session.
--- Only the dominant axis: `left`/`right` give the input panel a fixed
--- `windows.input.height`, so forcing a chat height there shuffles the panels, and
--- in `bottom` the chat spans the editor width, making a stored width meaningless.
--- Must run BEFORE `WidgetLayout.close`, which nils `win_nrs`.
function ChatWidget:_remember_size()
    local winid = self.win_nrs.chat
    if not winid or not self:visible_tab() then
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

--- Deletes all buffers and removes them from memory
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    -- The tab must outlive the widget, so the same fallback `hide` needs applies
    -- here. Everything else `hide` does is wrong for a destroy: it would capture
    -- a size no one can read back and reopen a float over deleted buffers.
    -- BEFORE `unregister`: `find_first_non_widget_window` recognises widget
    -- windows through `WidgetRegistry.all_bufnrs`, so unregistering first makes
    -- this widget's own chat window look like the fallback and no window is
    -- created.
    self:_ensure_fallback_window()

    WidgetRegistry.unregister(self)

    if self._winclosed_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self._winclosed_augroup)
        self._winclosed_augroup = nil
    end

    -- Close the windows directly rather than through `hide`.
    -- `WidgetLayout.close` skips every handle whose tabpage is already gone,
    -- which is what keeps this safe during a tabclose teardown on 0.11.x.
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

    -- Check if prompt is empty or contains only whitespace
    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    -- Ask session if it can accept this prompt
    local accepted = self.on_submit_input(prompt)
    if not accepted then
        return
    end

    -- Clear buffers only after successful submission
    vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})

    BufHelpers.with_modifiable(self.buf_nrs.code, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.files, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.diagnostics, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    self:close_optional_window("code")
    self:close_optional_window("files")
    self:close_optional_window("diagnostics")
    -- Move cursor to chat buffer after submit for easy access to permission requests
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

            -- make sure to scroll to the bottom
            -- 1. user can see the new message
            -- 2. auto-scroll will start again
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
    -- Own copy: every widget mutates its own `context` fields.
    self.headers = WindowDecoration.default_headers()

    self.buf_nrs = self:_create_buf_nrs()

    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)

    self:_bind_keymaps()

    -- One shared augroup for every widget; the handler resolves the owning
    -- widget per event through `WidgetRegistry`.
    BufferGuard.ensure()

    -- Track whether we're programmatically closing windows
    -- to avoid recursive hide() calls
    self._closing = false

    -- Named after the chat buffer: buffer numbers are globally unique and each
    -- widget creates its own chat buffer, so two widgets can never share a
    -- group name. A shared name would silently wipe the other widget's
    -- WinClosed autocmd, because nvim_create_augroup(name, { clear = true })
    -- returns the existing id after clearing it.
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
            -- Any widget window closed by the user closes the whole widget,
            -- except "todos" which can be closed independently.
            for _, winid in pairs(self.win_nrs) do
                if winid == closed_winid then
                    -- Synchronously, before the deferred `hide`: WinClosed fires
                    -- "just before it is removed from the window layout"
                    -- (`:h WinClosed`), so the chat window is still measurable
                    -- here. By the time the scheduled `hide` runs it is gone,
                    -- `visible_tab` is nil, and the user's resize is dropped.
                    -- Regression: chat_widget.test.lua::"keeps a manual width
                    -- when the user closes the chat window".
                    self:_remember_size()
                    vim.schedule(function()
                        self:hide()
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
                    -- call vim.paste directly to avoid coupling to the file list logic
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
    end

    -- Add keybindings to chat, todos, code, and files buffers to jump back to input and start insert mode
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

    local diagnostics = self:_create_new_buf({
        filetype = "AgenticDiagnostics",
    })

    local input = self:_create_new_buf({
        filetype = "AgenticInput",
        modifiable = true,
    })

    -- Don't call it for the chat buffer as its managed somewhere else
    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, diagnostics, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        diagnostics = diagnostics,
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

--- Computes the mode-aware submit/change-mode hint for the input header.
--- Both hints live on the input header only. Returns nil for modes with no
--- relevant binding (e.g. command mode) so callers keep the last shown hint.
--- @param mode string
--- @return string|nil suffix
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

--- Persists the input header suffix for the current mode and re-renders it.
--- @param mode string
function ChatWidget:_apply_input_suffix(mode)
    local suffix = ChatWidget._compute_input_suffix(mode)
    if suffix == nil then
        return
    end

    self.headers.input.suffix = suffix

    self:render_header("input")
end

--- Binds events to change the suffix header texts based on current mode keymaps
--- For the Chat and Input buffers only
function ChatWidget:_bind_events_to_change_headers()
    -- Seed the input header with the normal-mode hints immediately so it does
    -- not show the hard-coded default keys until the first mode change.
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

--- Wraps a window-closing operation with the _closing flag so the
--- WinClosed autocmd ignores programmatic closes.
--- @param fn fun()
function ChatWidget:_avoid_auto_close_cmd(fn)
    self._closing = true
    local ok, err = pcall(fn)
    self._closing = false
    if not ok then
        Logger.notify(tostring(err), vim.log.levels.ERROR)
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

--- Finds the first window in the widget's own tabpage that belongs to no widget.
---
--- Excludes any window showing a registered widget buffer, so one session cannot
--- eject a foreign buffer into a window showing another session's panel.
--- `BufferGuard`'s repurpose path re-registers the replacement buffer it swaps
--- in, so every window a widget created shows a registered buffer and this one
--- check sees them all.
--- Regression: chat_widget.test.lua::"never returns a window showing a
--- registered widget buffer it did not create".
--- @return number|nil winid The first non-widget window ID, or nil if none found
function ChatWidget:find_first_non_widget_window()
    local tab_page_id = self:visible_tab()
    if not tab_page_id then
        return nil
    end

    local all_windows = vim.api.nvim_tabpage_list_wins(tab_page_id)
    local widget_bufnrs = WidgetRegistry.all_bufnrs()

    for _, winid in ipairs(all_windows) do
        -- Skip floating windows (pickers, popups, etc.)
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

--- Opens a new editor window on the opposite side of the widget.
--- Position-aware: respects the current layout position.
--- @param bufnr number|nil The buffer to display in the new window
--- @return number|nil winid The newly created window ID or nil
function ChatWidget:open_editor_window(bufnr)
    if bufnr == nil then
        -- Try first oldfile under current directory
        local oldfiles = vim.v.oldfiles
        local cwd = vim.fn.getcwd()
        if oldfiles and #oldfiles > 0 then
            for _, filepath in ipairs(oldfiles) do
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

    -- Fallback: create new scratch buffer — safer than using
    -- alternate buffer (#) which could be a widget buffer
    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    -- Position-aware split using topleft/botright vim commands.
    -- These always create full-width/full-height splits
    -- regardless of which window is current.
    local split_cmd
    if self.current_position == "left" then
        split_cmd = "botright vsplit"
    elseif self.current_position == "bottom" then
        split_cmd = "topleft split"
    else
        -- "right" or any unknown → full-height left
        split_cmd = "topleft vsplit"
    end

    -- Use nvim_win_call to run the split in the widget's tabpage context
    -- without disturbing the user's focus when they're on another tab.
    local anchor_win = self.win_nrs.chat or self.win_nrs.input
    if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
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

--- Schedule a coalesced re-render of function-based headers.
--- Multiple calls within the same event loop tick collapse into one render.
function ChatWidget:schedule_header_refresh()
    if self._header_refresh_scheduled then
        return
    end
    if not Config.headers then
        return
    end

    self._header_refresh_scheduled = true
    -- Debounce updates within 150ms of each other to avoid excessive
    -- re-renders when multiple updates come in quick succession
    vim.defer_fn(function()
        self._header_refresh_scheduled = false
        self:_render_dynamic_headers()
    end, 150)
end

--- Re-render every session-driven header. The chat and input panels are
--- always dynamic (their default headers consume session_state), plus any
--- panel the user configured as a header function.
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
