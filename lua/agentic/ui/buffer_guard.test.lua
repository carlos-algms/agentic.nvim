-- lua/agentic/ui/buffer_guard.test.lua
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local BufferGuard = require("agentic.ui.buffer_guard")
local WidgetLayout = require("agentic.ui.widget_layout")
local BufHelpers = require("agentic.utils.buf_helpers")
local WidgetRegistry = require("agentic.ui.widget_registry")

local active_setups = {}

--- Helper: create a minimal widget-like setup in a fresh tab
--- @return table state { tab, bufs, wins, augroup, cleanup }
local function create_widget_setup()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    -- Create widget buffers
    local chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[chat_buf].buftype = "nofile"
    vim.bo[chat_buf].filetype = "AgenticChat"

    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "AgenticInput"

    --- @type {chat: integer, input: integer}
    local buf_nrs = { chat = chat_buf, input = input_buf }

    -- Create widget windows
    local chat_win = vim.api.nvim_open_win(chat_buf, false, {
        split = "right",
        win = -1,
    })
    local input_win = vim.api.nvim_open_win(input_buf, false, {
        split = "below",
        win = chat_win,
    })

    --- @type agentic.ui.ChatWidget.WinNrs
    local win_nrs = { chat = chat_win, input = input_win }

    -- The original (non-widget) window is the first one
    local all_wins = vim.api.nvim_tabpage_list_wins(tab)
    local editor_win = nil
    for _, w in ipairs(all_wins) do
        if w ~= chat_win and w ~= input_win then
            editor_win = w
            break
        end
    end

    -- Mark widget windows with their expected buffer
    vim.w[chat_win].agentic_bufnr = chat_buf
    vim.w[input_win].agentic_bufnr = input_buf

    local target_win = editor_win
    --- @type any
    local widget = {
        tab_page_id = tab,
        buf_nrs = buf_nrs,
        win_nrs = win_nrs,
        find_first_non_widget_window = function()
            if target_win and vim.api.nvim_win_is_valid(target_win) then
                return target_win
            end
            return nil
        end,
        open_editor_window = function()
            return nil
        end,
    }
    WidgetRegistry.register(widget)

    --- @type agentic.ui.BufferGuard.Callbacks
    local callbacks = {
        tab_page_id = tab,
        find_target_window = function()
            if target_win and vim.api.nvim_win_is_valid(target_win) then
                return target_win
            end
            return nil
        end,
    }

    local augroup = BufferGuard.attach(callbacks)

    local cleaned = false
    local setup = {
        tab = tab,
        bufs = buf_nrs,
        wins = win_nrs,
        editor_win = editor_win,
        widget = widget,
        augroup = augroup,
        set_target = function(winid)
            target_win = winid
        end,
        cleanup = function()
            if cleaned then
                return
            end
            cleaned = true
            BufferGuard.detach(augroup)
            WidgetRegistry.unregister(widget)
            pcall(function()
                if vim.api.nvim_tabpage_is_valid(tab) then
                    vim.api.nvim_set_current_tabpage(tab)
                    vim.cmd("tabclose!")
                end
            end)
        end,
    }
    active_setups[#active_setups + 1] = setup
    return setup
end

describe("BufferGuard", function()
    --- @type TestStub|nil
    local schedule_stub
    --- @type TestStub|nil
    local usable_stub
    --- @type TestSpy|nil
    local focus_spy
    --- @type table<integer, true>
    local baseline_tabs
    --- @type agentic.ui.ChatWidget[]
    local extra_widgets

    before_each(function()
        active_setups = {}
        baseline_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            baseline_tabs[tabpage] = true
        end
        extra_widgets = {}
        schedule_stub = nil
        usable_stub = nil
        focus_spy = nil
    end)

    after_each(function()
        if focus_spy then
            focus_spy:revert()
        end
        if usable_stub then
            usable_stub:revert()
        end
        if schedule_stub then
            schedule_stub:revert()
        end
        for _, setup in ipairs(active_setups) do
            setup.cleanup()
        end
        for _, widget in ipairs(extra_widgets) do
            WidgetRegistry.unregister(widget)
        end
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if not baseline_tabs[tabpage] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end
    end)

    it(
        "restores widget buffer when foreign buffer enters " .. "widget window",
        function()
            local s = create_widget_setup()

            -- Focus the chat widget window
            vim.api.nvim_set_current_win(s.wins.chat)

            -- Create a foreign buffer and force it into the
            -- widget window via API
            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(s.wins.chat, foreign)

            -- The guard fires on BufEnter and should have
            -- swapped back synchronously
            local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
            assert.equal(s.bufs.chat, buf_in_chat)

            s.cleanup()
        end
    )

    it("redirects the foreign buffer to the editor window", function()
        local s = create_widget_setup()
        local old_chat_buf = s.bufs.chat

        vim.api.nvim_set_current_win(s.wins.chat)

        -- Write a temp file so the foreign buffer has a name
        local tmpfile = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({ "-- test" }, tmpfile)

        vim.cmd("edit " .. vim.fn.fnameescape(tmpfile))

        -- Editor window should now display the file.
        -- Resolve symlinks before comparing (macOS: /var ->
        -- /private/var); nvim_buf_get_name returns the real path.
        local editor_buf = vim.api.nvim_win_get_buf(s.editor_win)
        local editor_name = vim.api.nvim_buf_get_name(editor_buf)
        local resolved_tmpfile = vim.fn.resolve(tmpfile)
        assert.equal(resolved_tmpfile, editor_name)

        -- Widget window should now hold a fresh replacement buffer
        local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
        assert.are_not.equal(old_chat_buf, buf_in_chat)
        assert.equal(buf_in_chat, s.widget.buf_nrs.chat)
        assert.equal(buf_in_chat, vim.w[s.wins.chat].agentic_bufnr)
        assert.is_nil(WidgetRegistry.get(old_chat_buf))
        assert.equal(s.widget, WidgetRegistry.get(buf_in_chat))

        os.remove(tmpfile)
        s.cleanup()
    end)

    it("re-resolves the deferred destination", function()
        local s = create_widget_setup()
        vim.api.nvim_set_current_win(s.wins.chat)

        local scheduled
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            scheduled = callback
        end)

        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)

        local later_win = vim.api.nvim_open_win(
            vim.api.nvim_create_buf(false, true),
            false,
            { split = "left", win = s.editor_win }
        )
        s.set_target(later_win)
        assert.is_not_nil(scheduled)
        scheduled()

        assert.equal(foreign, vim.api.nvim_win_get_buf(later_win))
        assert.equal(later_win, vim.api.nvim_get_current_win())

        schedule_stub:revert()
        schedule_stub = nil
        s.cleanup()
    end)

    it("rejects a deferred destination that is no longer usable", function()
        local s = create_widget_setup()
        vim.api.nvim_set_current_win(s.wins.chat)

        local scheduled
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            scheduled = callback
        end)

        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)
        assert.is_not_nil(scheduled)

        usable_stub = spy.stub(BufHelpers, "is_win_usable")
        usable_stub:returns(false)
        focus_spy = spy.on(vim.api, "nvim_set_current_win")

        scheduled()

        assert.spy(focus_spy).was.called(0)

        focus_spy:revert()
        focus_spy = nil
        usable_stub:revert()
        usable_stub = nil
        schedule_stub:revert()
        schedule_stub = nil
        s.cleanup()
    end)

    it("rejects a different widget that claims the owner buffer", function()
        local s = create_widget_setup()
        vim.api.nvim_set_current_win(s.wins.chat)

        local scheduled
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            scheduled = callback
        end)

        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)
        assert.is_not_nil(scheduled)

        --- @type any
        local replacement = {
            tab_page_id = s.tab,
            buf_nrs = { chat = s.widget.buf_nrs.chat },
            win_nrs = {},
            find_first_non_widget_window = function()
                return s.editor_win
            end,
            open_editor_window = function()
                return nil
            end,
        }
        extra_widgets[#extra_widgets + 1] = replacement
        WidgetRegistry.register(replacement)
        focus_spy = spy.on(vim.api, "nvim_set_current_win")

        scheduled()

        assert.spy(focus_spy).was.called(0)
    end)

    it("rejects a destination outside the owner's stored tabpage", function()
        local s = create_widget_setup()

        vim.cmd("tabnew")
        local foreign_tab = vim.api.nvim_get_current_tabpage()
        local foreign_win = vim.api.nvim_get_current_win()
        local original_foreign_buf = vim.api.nvim_win_get_buf(foreign_win)
        s.set_target(foreign_win)

        vim.api.nvim_set_current_tabpage(s.tab)
        vim.api.nvim_set_current_win(s.wins.chat)
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)

        assert.equal(
            s.widget.buf_nrs.chat,
            vim.api.nvim_win_get_buf(s.wins.chat)
        )
        assert.equal(
            original_foreign_buf,
            vim.api.nvim_win_get_buf(foreign_win)
        )
        assert.equal(foreign_tab, vim.api.nvim_win_get_tabpage(foreign_win))

        s.cleanup()
    end)

    it(
        "does not redirect when widget buffer enters its own " .. "window",
        function()
            local s = create_widget_setup()

            vim.api.nvim_set_current_win(s.wins.chat)
            vim.api.nvim_win_set_buf(s.wins.chat, s.bufs.chat)

            local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
            assert.equal(s.bufs.chat, buf_in_chat)

            s.cleanup()
        end
    )

    it("creates a new split when no editor window exists", function()
        vim.cmd("tabnew")
        local tab = vim.api.nvim_get_current_tabpage()

        local chat_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[chat_buf].buftype = "nofile"

        -- Only one window — make it the widget window
        local chat_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(chat_win, chat_buf)

        -- Mark the widget window
        vim.w[chat_win].agentic_bufnr = chat_buf

        local augroup = BufferGuard.attach({
            tab_page_id = tab,
            find_target_window = function()
                -- Mimics open_editor_window: create a split
                local new_buf = vim.api.nvim_create_buf(false, true)
                local ok, winid = pcall(
                    vim.api.nvim_open_win,
                    new_buf,
                    true,
                    { split = "left", win = -1 }
                )
                if ok then
                    return winid
                end
                return nil
            end,
        })

        --- @type any
        local widget = {
            tab_page_id = tab,
            buf_nrs = { chat = chat_buf },
            win_nrs = { chat = chat_win },
            find_first_non_widget_window = function()
                return nil
            end,
            open_editor_window = function()
                local new_buf = vim.api.nvim_create_buf(false, true)
                local ok, winid = pcall(
                    vim.api.nvim_open_win,
                    new_buf,
                    true,
                    { split = "left", win = -1 }
                )
                if ok then
                    return winid
                end
                return nil
            end,
        }
        WidgetRegistry.register(widget)

        -- Force a foreign buffer in
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(chat_win, foreign)

        -- Widget buffer should be restored
        local buf_in_chat = vim.api.nvim_win_get_buf(chat_win)
        assert.equal(chat_buf, buf_in_chat)

        -- A new window should have been created
        local all_wins = vim.api.nvim_tabpage_list_wins(tab)
        assert.is_true(#all_wins > 1)

        BufferGuard.detach(augroup)
        WidgetRegistry.unregister(widget)
        pcall(function()
            vim.cmd("tabclose!")
        end)
    end)

    it("detach removes the autocmd group", function()
        local s = create_widget_setup()

        BufferGuard.detach(s.augroup)

        -- After detach, forcing a foreign buffer should NOT
        -- be intercepted
        vim.api.nvim_set_current_win(s.wins.chat)
        local foreign = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(s.wins.chat, foreign)

        -- The foreign buffer should stay (no guard active)
        local buf_in_chat = vim.api.nvim_win_get_buf(s.wins.chat)
        assert.equal(foreign, buf_in_chat)

        WidgetRegistry.unregister(s.widget)

        pcall(function()
            vim.cmd("tabclose!")
        end)
    end)

    it(
        "does not leak widget window options to the editor window after redirect",
        function()
            -- Widget windows hold panel-styled options (no number column,
            -- no signcolumn, custom winhighlight, etc.). When a foreign
            -- buffer briefly cohabits a widget window before being
            -- redirected, those window-local options must not follow the
            -- buffer to its target window.
            --
            -- Forces non-default global options so a leak from PANEL
            -- defaults is observable as a divergence on the editor window.
            local saved = {
                number = vim.o.number,
                signcolumn = vim.o.signcolumn,
                cursorline = vim.o.cursorline,
                list = vim.o.list,
            }
            vim.o.number = true
            vim.o.signcolumn = "yes"
            vim.o.cursorline = true
            vim.o.list = true

            vim.cmd("tabnew")
            local tab_page_id = vim.api.nvim_get_current_tabpage()

            local win_nrs = {}
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            -- Editor window in this tab is the one created by :tabnew
            local editor_win = vim.api.nvim_get_current_win()

            WidgetLayout.open({
                tab_page_id = tab_page_id,
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                position = "right",
                focus_prompt = false,
            })

            -- Snapshot editor window options BEFORE any cohabit cycle
            local editor_before = {
                number = vim.wo[editor_win].number,
                signcolumn = vim.wo[editor_win].signcolumn,
                cursorline = vim.wo[editor_win].cursorline,
                list = vim.wo[editor_win].list,
                winhighlight = vim.wo[editor_win].winhighlight,
                statuscolumn = vim.wo[editor_win].statuscolumn,
                fillchars = vim.wo[editor_win].fillchars,
                scrolloff = vim.wo[editor_win].scrolloff,
                foldcolumn = vim.wo[editor_win].foldcolumn,
            }

            local augroup = BufferGuard.attach({
                tab_page_id = tab_page_id,
                find_target_window = function()
                    if vim.api.nvim_win_is_valid(editor_win) then
                        return editor_win
                    end
                    return nil
                end,
            })

            --- @type any
            local widget = {
                tab_page_id = tab_page_id,
                buf_nrs = buf_nrs,
                win_nrs = win_nrs,
                find_first_non_widget_window = function()
                    return editor_win
                end,
                open_editor_window = function()
                    return nil
                end,
            }
            WidgetRegistry.register(widget)

            -- Force a foreign buffer into the chat widget window. This
            -- triggers BufEnter inside the widget and, in turn, a
            -- redirect to the editor window via BufferGuard.
            vim.api.nvim_set_current_win(win_nrs.chat)
            local foreign = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(foreign, vim.fn.tempname() .. "_leak.txt")
            vim.api.nvim_win_set_buf(win_nrs.chat, foreign)

            -- Editor window should now hold the foreign buffer with its
            -- ORIGINAL options intact, not panel-styled.
            assert.equal(foreign, vim.api.nvim_win_get_buf(editor_win))
            assert.equal(editor_before.number, vim.wo[editor_win].number)
            assert.equal(
                editor_before.signcolumn,
                vim.wo[editor_win].signcolumn
            )
            assert.equal(
                editor_before.cursorline,
                vim.wo[editor_win].cursorline
            )
            assert.equal(editor_before.list, vim.wo[editor_win].list)
            assert.equal(
                editor_before.winhighlight,
                vim.wo[editor_win].winhighlight
            )
            assert.equal(
                editor_before.statuscolumn,
                vim.wo[editor_win].statuscolumn
            )
            assert.equal(editor_before.fillchars, vim.wo[editor_win].fillchars)
            assert.equal(editor_before.scrolloff, vim.wo[editor_win].scrolloff)
            assert.equal(
                editor_before.foldcolumn,
                vim.wo[editor_win].foldcolumn
            )

            BufferGuard.detach(augroup)
            WidgetRegistry.unregister(widget)
            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose!")
            end)

            vim.o.number = saved.number
            vim.o.signcolumn = saved.signcolumn
            vim.o.cursorline = saved.cursorline
            vim.o.list = saved.list
        end
    )
end)

-- Child process tests for cursor-follow behavior.
-- vim.schedule callbacks require event loop processing that
-- can't be safely done in same-process mini.test (vim.wait
-- escapes pcall, causing silent test skips). Child process
-- tests use RPC round-trips to flush the event loop.
local Child = require("tests.helpers.child")

describe("BufferGuard cursor follow (child)", function()
    local child = Child.new()

    --- Set up widget layout in child: editor_win | chat_win.
    --- Attaches BufferGuard and focuses the chat window.
    --- @return integer editor_win
    --- @return integer chat_win
    local function setup_widget_in_child()
        local editor_win = child.api.nvim_get_current_win()

        local chat_buf = child.api.nvim_create_buf(false, true)
        child.bo[chat_buf].buftype = "nofile"

        local chat_win = child.api.nvim_open_win(chat_buf, true, {
            split = "right",
            win = -1,
        })

        -- vim.w[winid] assignment and BG.attach (which needs a
        -- callback function) can't cross the RPC boundary.
        child.lua(
            [[
            local BG = require("agentic.ui.buffer_guard")
            local WidgetRegistry = require("agentic.ui.widget_registry")
            local editor_win, chat_win, chat_buf = ...

            vim.w[chat_win].agentic_bufnr = chat_buf

            local widget = {
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                buf_nrs = { chat = chat_buf },
                win_nrs = { chat = chat_win },
                find_first_non_widget_window = function()
                    return editor_win
                end,
                open_editor_window = function()
                    return nil
                end,
            }
            WidgetRegistry.register(widget)

            BG.attach({
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                find_target_window = function()
                    if vim.api.nvim_win_is_valid(editor_win) then
                        return editor_win
                    end
                end,
            })
        ]],
            { editor_win, chat_win, chat_buf }
        )

        child.api.nvim_set_current_win(chat_win)

        return editor_win, chat_win
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("moves cursor to editor window after foreign buffer redirect", function()
        local editor_win, chat_win = setup_widget_in_child()

        -- Force a foreign buffer into the widget window
        local foreign = child.api.nvim_create_buf(true, false)
        child.api.nvim_win_set_buf(chat_win, foreign)

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        -- Cursor should have followed the foreign buffer
        assert.equal(editor_win, child.api.nvim_get_current_win())

        -- Editor window should have the foreign buffer
        assert.equal(foreign, child.api.nvim_win_get_buf(editor_win))
    end)

    it("moves cursor to editor window after :edit in widget window", function()
        local tmpfile = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({ "-- test" }, tmpfile)

        local editor_win = setup_widget_in_child()

        -- :edit a file while in the widget window
        child.cmd("edit " .. child.fn.fnameescape(tmpfile))

        -- Flush scheduled cursor-follow callback
        child.flush()
        vim.uv.sleep(50)

        -- Cursor should be in the editor window
        assert.equal(editor_win, child.api.nvim_get_current_win())

        -- Editor window should display the file
        local editor_buf = child.api.nvim_win_get_buf(editor_win)
        local editor_name = child.api.nvim_buf_get_name(editor_buf)
        assert.equal(vim.fn.resolve(tmpfile), editor_name)

        os.remove(tmpfile)
    end)
end)
