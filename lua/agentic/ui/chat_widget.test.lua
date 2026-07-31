local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local WindowDecoration = require("agentic.ui.window_decoration")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    --- @param widget agentic.ui.ChatWidget
    --- @param name string
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    -- Layout-independent behavior
    for _, position in ipairs({ "right", "left", "bottom" }) do
        -- Bottom uses 2 to avoid touching the screen edge
        local padding = position == "bottom" and 2 or 1

        describe(string.format("(%s layout)", position), function()
            local widget_tab
            local widget
            local original_position
            --- @type table<integer, boolean>
            local baseline_tabs
            local repurposed_chat_buf
            local sticky_tmpfile
            local sticky_float_win
            local sticky_float_buf

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = position
                baseline_tabs = {}
                for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                    baseline_tabs[tabpage] = true
                end
                repurposed_chat_buf = nil
                sticky_tmpfile = nil
                sticky_float_win = nil
                sticky_float_buf = nil

                vim.cmd("tabnew")
                widget_tab = vim.api.nvim_get_current_tabpage()

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(on_submit_spy --[[@as function]])
            end)

            after_each(function()
                if widget then
                    pcall(function()
                        widget:destroy()
                    end)
                end

                if
                    sticky_float_win
                    and vim.api.nvim_win_is_valid(sticky_float_win)
                then
                    vim.api.nvim_win_close(sticky_float_win, true)
                end
                for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                    if not baseline_tabs[tabpage] then
                        vim.cmd(
                            "tabclose! "
                                .. vim.api.nvim_tabpage_get_number(tabpage)
                        )
                    end
                end
                if
                    repurposed_chat_buf
                    and vim.api.nvim_buf_is_valid(repurposed_chat_buf)
                then
                    vim.api.nvim_buf_delete(
                        repurposed_chat_buf,
                        { force = true }
                    )
                end
                if
                    sticky_float_buf
                    and vim.api.nvim_buf_is_valid(sticky_float_buf)
                then
                    vim.api.nvim_buf_delete(sticky_float_buf, { force = true })
                end
                if sticky_tmpfile then
                    os.remove(sticky_tmpfile)
                end

                Config.windows.position = original_position
            end)

            it("creates widget with valid buffer IDs", function()
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
            end)

            it(
                "show() creates chat and input windows only when buffers are empty",
                function()
                    assert.is_falsy(widget:is_open())

                    widget:show()

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                    )
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.input)
                    )
                    assert.is_nil(widget.win_nrs.code)
                    assert.is_nil(widget.win_nrs.files)
                    assert.is_nil(widget.win_nrs.todos)
                end
            )

            it("hide() closes all windows and preserves buffers", function()
                widget:show()

                local chat_win = widget.win_nrs.chat
                local input_win = widget.win_nrs.input
                local chat_buf = widget.buf_nrs.chat
                local input_buf = widget.buf_nrs.input

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(chat_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                assert.is_nil(widget.win_nrs.chat)
                assert.is_nil(widget.win_nrs.input)
                assert.is_falsy(widget:is_open())

                assert.equal(chat_buf, widget.buf_nrs.chat)
                assert.equal(input_buf, widget.buf_nrs.input)
                assert.is_true(vim.api.nvim_buf_is_valid(chat_buf))
                assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
            end)

            it("show() is idempotent when called multiple times", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat

                widget:show()

                assert.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("hide() is safe when called multiple times", function()
                widget:show()
                widget:hide()

                assert.has_no_errors(function()
                    widget:hide()
                end)
            end)

            it("show() after hide() creates new windows", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat
                widget:hide()

                widget:show()

                assert.are_not.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_false(vim.api.nvim_win_is_valid(first_chat_win))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("windows are created in correct tabpage", function()
                widget:show()

                assert.equal(
                    widget_tab,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.chat)
                )
                assert.equal(
                    widget_tab,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.input)
                )
            end)

            it("hide() stops insert mode", function()
                widget:show()
                vim.api.nvim_set_current_win(widget.win_nrs.input)
                vim.cmd("startinsert")

                widget:hide()

                assert.are_not.equal("i", vim.fn.mode())
            end)

            describe("dynamic window creation", function()
                local test_cases = {
                    {
                        name = "code",
                        content = { "local foo = 'bar'", "print(foo)" },
                    },
                    {
                        name = "files",
                        content = { "file1.lua", "file2.lua" },
                    },
                    {
                        name = "todos",
                        content = { "todo1", "todo2" },
                    },
                }

                for _, tc in ipairs(test_cases) do
                    it(
                        string.format(
                            "creates %s window when buffer has content",
                            tc.name
                        ),
                        function()
                            fill_buffer(widget, tc.name, tc.content)
                            widget:show()

                            assert.is_true(
                                vim.api.nvim_win_is_valid(
                                    widget.win_nrs[tc.name]
                                )
                            )
                            assert.equal(
                                widget_tab,
                                vim.api.nvim_win_get_tabpage(
                                    widget.win_nrs[tc.name]
                                )
                            )
                        end
                    )
                end
            end)

            describe("sticky windows", function()
                it("redirects :edit to editor window", function()
                    widget:show()

                    local chat_win = widget.win_nrs.chat

                    vim.api.nvim_set_current_win(chat_win)

                    sticky_tmpfile = vim.fn.tempname() .. ".lua"
                    vim.fn.writefile({ "-- test" }, sticky_tmpfile)
                    repurposed_chat_buf = widget.buf_nrs.chat

                    vim.cmd("edit " .. vim.fn.fnameescape(sticky_tmpfile))

                    -- Guard restored chat_buf or swapped in a fresh scratch buffer
                    local buf_in_chat = vim.api.nvim_win_get_buf(chat_win)
                    local name_in_chat = vim.api.nvim_buf_get_name(buf_in_chat)
                    local resolved_in_chat = vim.fn.resolve(name_in_chat)
                    local resolved_tmpfile = vim.fn.resolve(sticky_tmpfile)
                    assert.are_not.equal(resolved_tmpfile, resolved_in_chat)

                    -- Temp file lands in a non-widget window, same tabpage
                    local found_in_non_widget = false
                    local all_wins = vim.api.nvim_tabpage_list_wins(widget_tab)
                    local widget_win_ids = {}
                    for _, wid in pairs(widget.win_nrs) do
                        if wid then
                            widget_win_ids[wid] = true
                        end
                    end
                    for _, wid in ipairs(all_wins) do
                        if not widget_win_ids[wid] then
                            local buf = vim.api.nvim_win_get_buf(wid)
                            local name = vim.api.nvim_buf_get_name(buf)
                            if vim.fn.resolve(name) == resolved_tmpfile then
                                found_in_non_widget = true
                            end
                        end
                    end
                    assert.is_true(found_in_non_widget)
                end)

                it(
                    "does not interfere with normal widget buffer changes",
                    function()
                        widget:show()

                        local chat_win = widget.win_nrs.chat
                        local input_win = widget.win_nrs.input
                        local chat_buf = widget.buf_nrs.chat
                        local input_buf = widget.buf_nrs.input

                        -- A widget buffer, but the WRONG one for this window
                        vim.api.nvim_set_current_win(chat_win)
                        vim.api.nvim_win_set_buf(chat_win, input_buf)

                        assert.equal(
                            chat_buf,
                            vim.api.nvim_win_get_buf(chat_win)
                        )
                        assert.equal(
                            input_buf,
                            vim.api.nvim_win_get_buf(input_win)
                        )
                    end
                )

                it(
                    "leaves the shared buffer guard alive after destroy",
                    function()
                        widget:show()
                        widget:destroy()

                        -- Augroup is module-wide: tearing it down on destroy
                        -- would disarm every other session's guard.
                        local autocmds = vim.api.nvim_get_autocmds({
                            group = "AgenticBufferGuard",
                            event = "BufEnter",
                        })
                        assert.equal(1, #autocmds)

                        -- Prevent double-destroy in after_each
                        widget = nil
                    end
                )

                it(
                    "skips floating windows in find_first_non_widget_window",
                    function()
                        widget:show()

                        -- Leave only widget windows on the tabpage
                        local all_wins =
                            vim.api.nvim_tabpage_list_wins(widget_tab)
                        local widget_win_ids = {}
                        for _, wid in pairs(widget.win_nrs) do
                            if wid then
                                widget_win_ids[wid] = true
                            end
                        end
                        for _, wid in ipairs(all_wins) do
                            if not widget_win_ids[wid] then
                                pcall(vim.api.nvim_win_close, wid, true)
                            end
                        end

                        sticky_float_buf = vim.api.nvim_create_buf(false, true)
                        sticky_float_win =
                            vim.api.nvim_open_win(sticky_float_buf, false, {
                                relative = "editor",
                                width = 10,
                                height = 3,
                                row = 1,
                                col = 1,
                            })

                        local result = widget:find_first_non_widget_window()
                        assert.is_nil(result)
                    end
                )
            end)

            it("hide() closes all dynamic windows when they exist", function()
                for _, name in ipairs({ "files", "code", "todos" }) do
                    fill_buffer(widget, name, { "content" })
                end

                widget:show()

                local files_win = widget.win_nrs.files
                local code_win = widget.win_nrs.code
                local todos_win = widget.win_nrs.todos

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(files_win))
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_false(vim.api.nvim_win_is_valid(todos_win))
                assert.is_nil(widget.win_nrs.files)
                assert.is_nil(widget.win_nrs.code)
                assert.is_nil(widget.win_nrs.todos)
            end)

            it("caps window height at max_height", function()
                local lines = {}
                for i = 1, 23 do
                    lines[i] = "line" .. i
                end
                fill_buffer(widget, "code", lines)

                widget:show()

                local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(15, height)
            end)

            it(
                string.format("dynamic window uses %d line(s) padding", padding),
                function()
                    fill_buffer(widget, "code", { "line1", "line2", "line3" })

                    widget:show()

                    local height =
                        vim.api.nvim_win_get_height(widget.win_nrs.code)
                    assert.equal(3 + padding, height)
                end
            )

            it("resizes window when content changes", function()
                fill_buffer(widget, "code", { "line1", "line2", "line3" })

                widget:show()
                assert.equal(
                    3 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    3,
                    3,
                    false,
                    { "line4", "line5", "line6", "line7" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    7 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            it("shrinks window when content is removed", function()
                fill_buffer(
                    widget,
                    "code",
                    { "line1", "line2", "line3", "line4", "line5" }
                )

                widget:show()
                assert.equal(
                    5 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    2 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            describe("show() re-renders dynamic windows", function()
                it("closes window when buffer becomes empty", function()
                    fill_buffer(widget, "code", { "line1" })

                    widget:show()
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )

                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.code,
                        0,
                        -1,
                        false,
                        {}
                    )

                    widget:show({ focus_prompt = false })

                    assert.is_nil(widget.win_nrs.code)
                end)

                it("creates window on show when content exists", function()
                    fill_buffer(widget, "code", { "line1" })

                    assert.has_no_errors(function()
                        widget:show({ focus_prompt = false })
                    end)

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )
                end)
            end)

            describe("WinClosed autocmd", function()
                -- WinClosed sets `_closing` synchronously, resetting it only
                -- inside `vim.schedule`, which never runs in same-process
                -- tests. So `_closing == true` means it scheduled hide().

                it(
                    "close_optional_window does not trigger WinClosed handler",
                    function()
                        fill_buffer(widget, "code", { "line1" })
                        fill_buffer(widget, "files", { "file.lua" })

                        widget:show()
                        assert.is_not_nil(widget.win_nrs.code)
                        assert.is_not_nil(widget.win_nrs.files)

                        widget:close_optional_window("code")

                        assert.is_nil(widget.win_nrs.code)
                        assert.is_false(widget._closing)
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                        )
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.input)
                        )
                    end
                )

                it(
                    "close_optional_window for files does not trigger WinClosed handler",
                    function()
                        fill_buffer(widget, "files", { "file.lua" })

                        widget:show()
                        assert.is_not_nil(widget.win_nrs.files)

                        widget:close_optional_window("files")

                        assert.is_nil(widget.win_nrs.files)
                        assert.is_false(widget._closing)
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                        )
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.input)
                        )
                    end
                )

                it(
                    "close_optional_window for diagnostics does not trigger WinClosed handler",
                    function()
                        fill_buffer(
                            widget,
                            "diagnostics",
                            { "diagnostic info" }
                        )

                        widget:show()
                        assert.is_not_nil(widget.win_nrs.diagnostics)

                        widget:close_optional_window("diagnostics")

                        assert.is_nil(widget.win_nrs.diagnostics)
                        assert.is_false(widget._closing)
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                        )
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.input)
                        )
                    end
                )

                it(
                    "close_optional_window for todos does not trigger WinClosed handler",
                    function()
                        fill_buffer(widget, "todos", { "- [ ] task" })

                        widget:show()
                        assert.is_not_nil(widget.win_nrs.todos)

                        widget:close_optional_window("todos")

                        assert.is_nil(widget.win_nrs.todos)
                        assert.is_false(widget._closing)
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                        )
                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs.input)
                        )
                    end
                )
            end)
        end)
    end

    -- Right and left differ only in split direction
    for _, side in ipairs({ "right", "left" }) do
        describe(string.format("(%s layout) specific", side), function()
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = side

                vim.cmd("tabnew")

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(on_submit_spy --[[@as function]])
            end)

            after_each(function()
                if widget then
                    pcall(function()
                        widget:destroy()
                    end)
                end
                pcall(function()
                    vim.cmd("tabclose")
                end)

                Config.windows.position = original_position
            end)

            it("input splits below chat", function()
                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                assert.is_true(input_pos[1] > chat_pos[1])
                assert.equal(chat_pos[2], input_pos[2])
            end)

            it("input has fixed height", function()
                widget:show()

                local input_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.input)
                assert.equal(Config.windows.input.height, input_height)
            end)
        end)
    end

    describe("(bottom layout) specific", function()
        local widget
        local original_position

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "bottom"

            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)

            Config.windows.position = original_position
        end)

        it("input splits right of chat", function()
            widget:show()

            local chat_pos = vim.api.nvim_win_get_position(widget.win_nrs.chat)
            local input_pos =
                vim.api.nvim_win_get_position(widget.win_nrs.input)

            assert.equal(chat_pos[1], input_pos[1])
            assert.is_true(input_pos[2] > chat_pos[2])
        end)

        it(
            "input width is proportional to chat via stack_width_ratio",
            function()
                widget:show()

                local chat_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.chat)
                local input_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.input)
                local ratio = Config.windows.stack_width_ratio

                local expected = math.floor((chat_width + input_width) * ratio)

                -- +-1 rounding tolerance
                assert.is_true(math.abs(input_width - expected) <= 1)
            end
        )
    end)

    describe("rotate_layout", function()
        local widget
        local original_position
        local show_stub
        local notify_stub
        local widget2
        local show_stub2

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])

            show_stub = spy.stub(widget, "show")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            if show_stub2 then
                show_stub2:revert()
                show_stub2 = nil
            end
            if widget2 then
                pcall(function()
                    widget2:destroy()
                end)
                widget2 = nil
            end

            show_stub:revert()
            notify_stub:revert()

            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end

            Config.windows.position = original_position
        end)

        it("uses default layouts when none provided", function()
            widget:rotate_layout()

            assert.equal("bottom", widget.current_position)
        end)

        it("uses default layouts when empty array provided", function()
            widget:rotate_layout({})

            assert.equal("bottom", widget.current_position)
        end)

        it(
            "stays on same layout and warns when only one is provided",
            function()
                widget.current_position = "bottom"

                widget:rotate_layout({ "bottom" })

                assert.equal("bottom", widget.current_position)
                assert.spy(notify_stub).was.called(1)
                local msg = notify_stub.calls[1][1]
                assert.is_true(msg:find("Only one layout") ~= nil)
            end
        )

        it("rotates through all layouts in order", function()
            local layouts = { "right", "bottom", "left" }

            widget:rotate_layout(layouts)
            assert.equal("bottom", widget.current_position)

            widget:rotate_layout(layouts)
            assert.equal("left", widget.current_position)

            widget:rotate_layout(layouts)
            assert.equal("right", widget.current_position)
        end)

        it("falls back to first layout when current is not in list", function()
            widget.current_position = "bottom"

            widget:rotate_layout({ "right", "left" })

            assert.equal("right", widget.current_position)
        end)

        it("calls show with focus_prompt false", function()
            widget:rotate_layout()

            assert.spy(show_stub).was.called(1)
            local call_args = show_stub.calls[1]
            -- [1] is self, [2] the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)

        it("does not mutate Config.windows.position", function()
            widget:rotate_layout()

            assert.equal("right", Config.windows.position)
            assert.equal("bottom", widget.current_position)
        end)

        it("two widgets rotate independently", function()
            local on_submit_spy2 = spy.new(function() end)
            widget2 = ChatWidget:new(on_submit_spy2 --[[@as function]])
            show_stub2 = spy.stub(widget2, "show")

            -- Both start at "right" (Config default)
            assert.equal("right", widget.current_position)
            assert.equal("right", widget2.current_position)

            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("right", widget2.current_position)

            widget2:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("bottom", widget2.current_position)

            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("left", widget.current_position)
            assert.equal("bottom", widget2.current_position)
        end)
    end)

    describe("size memory", function()
        local widget
        local widget2
        local widget3
        local original_position
        local saved_sessions

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"
            saved_sessions = SessionRegistry.sessions
            SessionRegistry.sessions = {}

            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            -- `pairs` is hole-safe: any subset of the three may exist.
            for _, w in pairs({ widget, widget2, widget3 }) do
                pcall(function()
                    w:destroy()
                end)
            end
            widget = nil
            widget2 = nil
            widget3 = nil

            pcall(function()
                vim.cmd("tabclose")
            end)

            SessionRegistry.sessions = saved_sessions
            Config.windows.position = original_position
        end)

        --- Registers `w`'s session under `key` so size seeding reaches it
        --- @param key integer
        --- @param w any
        local function register_session(key, w)
            --- @type any
            local session = { widget = w }
            SessionRegistry.sessions[key] = session
        end

        it("uses the configured width for the first widget", function()
            widget:show({ focus_prompt = false })

            -- 40% of the 80-column headless editor
            assert.equal(32, vim.api.nvim_win_get_width(widget.win_nrs.chat))
        end)

        it("preserves a manual chat width across hide and show", function()
            widget:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget.win_nrs.chat, 50)

            widget:hide()
            widget:show({ focus_prompt = false })

            assert.equal(50, vim.api.nvim_win_get_width(widget.win_nrs.chat))
        end)

        it("inherits the stored width of an existing session", function()
            widget:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget.win_nrs.chat, 50)
            widget:hide()
            register_session(1, widget)

            local on_submit_spy = spy.new(function() end)
            widget2 = ChatWidget:new(on_submit_spy --[[@as function]])
            register_session(2, widget2)
            widget2:show({ focus_prompt = false })

            assert.equal(50, vim.api.nvim_win_get_width(widget2.win_nrs.chat))
        end)

        it("preserves height but not width in the bottom layout", function()
            widget.current_position = "bottom"
            widget:show({ focus_prompt = false })
            local initial_width =
                vim.api.nvim_win_get_width(widget.win_nrs.chat)
            BufHelpers.win_set_height(widget.win_nrs.chat, 12)
            BufHelpers.win_set_width(widget.win_nrs.chat, 20)

            widget:hide()
            widget:show({ focus_prompt = false })

            assert.equal(12, vim.api.nvim_win_get_height(widget.win_nrs.chat))
            assert.equal(
                initial_width,
                vim.api.nvim_win_get_width(widget.win_nrs.chat)
            )
        end)

        it(
            "skips a stored size that lacks the axis the new layout needs",
            function()
                -- Session 1 only ran `bottom`: stores height, no width. Stopping
                -- there hands a `right` widget a width-less size, silently
                -- falling back to the configured one.
                widget.current_position = "bottom"
                widget:show({ focus_prompt = false })
                BufHelpers.win_set_height(widget.win_nrs.chat, 12)
                widget:hide()

                widget2 =
                    ChatWidget:new(spy.new(function() end) --[[@as function]])
                widget2:show({ focus_prompt = false })
                BufHelpers.win_set_width(widget2.win_nrs.chat, 50)
                widget2:hide()

                register_session(1, widget)
                register_session(2, widget2)

                widget3 =
                    ChatWidget:new(spy.new(function() end) --[[@as function]])
                widget3:show({ focus_prompt = false })

                assert.equal(
                    50,
                    vim.api.nvim_win_get_width(widget3.win_nrs.chat)
                )
            end
        )

        it("copies the inherited size instead of sharing the table", function()
            widget:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget.win_nrs.chat, 50)
            widget:hide()
            register_session(1, widget)

            -- Only session 1 registered, so later widgets seed from `widget`.
            -- A shared table would let this resize rewrite session 1's width,
            -- and widget3 would inherit 60.
            widget2 = ChatWidget:new(spy.new(function() end) --[[@as function]])
            widget2:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget2.win_nrs.chat, 60)
            widget2:hide()

            widget3 = ChatWidget:new(spy.new(function() end) --[[@as function]])
            widget3:show({ focus_prompt = false })

            assert.equal(50, vim.api.nvim_win_get_width(widget3.win_nrs.chat))
        end)

        it("keeps the remembered width when hide runs twice", function()
            widget:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget.win_nrs.chat, 50)

            widget:hide()
            -- Second `hide` has no chat window; measuring anyway would
            -- overwrite the stored width with the current window's.
            widget:hide()

            widget:show({ focus_prompt = false })

            assert.equal(50, vim.api.nvim_win_get_width(widget.win_nrs.chat))
        end)

        it("restores the width after rotating away and back", function()
            widget:show({ focus_prompt = false })
            BufHelpers.win_set_width(widget.win_nrs.chat, 50)

            widget:rotate_layout({ "right", "bottom" })
            assert.equal("bottom", widget.current_position)
            widget:rotate_layout({ "right", "bottom" })

            assert.equal("right", widget.current_position)
            assert.equal(50, vim.api.nvim_win_get_width(widget.win_nrs.chat))
        end)
    end)

    describe("hidden chat window lifecycle", function()
        local widget

        before_each(function()
            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it(
            "opens a hidden float on the chat buffer at construction time",
            function()
                assert.is_not_nil(widget._hidden_chat_winid)
                assert.is_true(
                    vim.api.nvim_win_is_valid(widget._hidden_chat_winid)
                )
                assert.equal(
                    vim.api.nvim_win_get_buf(widget._hidden_chat_winid),
                    widget.buf_nrs.chat
                )
                local cfg =
                    vim.api.nvim_win_get_config(widget._hidden_chat_winid)
                assert.is_true(cfg.hide)
            end
        )

        it("closes hidden chat window before opening visible widget", function()
            local hidden = widget._hidden_chat_winid
            assert.is_true(vim.api.nvim_win_is_valid(hidden))

            widget:show({ focus_prompt = false })

            assert.is_false(vim.api.nvim_win_is_valid(hidden))
            assert.is_nil(widget._hidden_chat_winid)
            assert.is_not_nil(widget.win_nrs.chat)
            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
        end)

        it("opens hidden chat window after hiding visible widget", function()
            widget:show({ focus_prompt = false })
            assert.is_nil(widget._hidden_chat_winid)

            widget:hide()

            assert.is_not_nil(widget._hidden_chat_winid)
            assert.is_true(vim.api.nvim_win_is_valid(widget._hidden_chat_winid))
            assert.equal(
                vim.api.nvim_win_get_buf(widget._hidden_chat_winid),
                widget.buf_nrs.chat
            )
        end)

        it(
            "preserves manual folds across hide/show via hidden chat window",
            function()
                local Fold = require("agentic.ui.tool_call_fold")

                local saved_folding = Config.folding
                Config.folding = {
                    tool_calls = {
                        enabled = true,
                        threshold = 5,
                        fold_on_error = false,
                    },
                }

                vim.bo[widget.buf_nrs.chat].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.chat,
                    0,
                    -1,
                    false,
                    vim.fn["repeat"]({ "L" }, 60)
                )

                widget:show({ focus_prompt = false })
                Fold.close_range(widget.buf_nrs.chat, 10, 25)
                widget:hide()

                Fold.close_range(widget.buf_nrs.chat, 35, 50)

                widget:show({ focus_prompt = false })
                local chat_win = widget.win_nrs.chat
                vim.api.nvim_win_call(chat_win, function()
                    assert.equal(vim.fn.foldclosed(15), 10)
                    assert.equal(vim.fn.foldclosedend(15), 25)
                    assert.equal(vim.fn.foldclosed(40), 35)
                    assert.equal(vim.fn.foldclosedend(40), 50)
                end)

                Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
            end
        )

        it("tears down the hidden chat window on destroy", function()
            local widget_ref = widget
            local hidden = widget._hidden_chat_winid
            assert.is_true(vim.api.nvim_win_is_valid(hidden))

            widget:destroy()
            widget = nil

            assert.is_false(vim.api.nvim_win_is_valid(hidden))
            assert.is_nil(widget_ref._hidden_chat_winid)
        end)

        it("does not leak a hidden float across hide() calls", function()
            widget:show({ focus_prompt = false })
            widget:hide()

            local first_hidden = widget._hidden_chat_winid
            assert.is_not_nil(first_hidden)

            widget:hide()

            assert.is_false(vim.api.nvim_win_is_valid(first_hidden))
            assert.is_not_nil(widget._hidden_chat_winid)
            assert.is_true(vim.api.nvim_win_is_valid(widget._hidden_chat_winid))
        end)
    end)

    describe("get_visible_tab_id", function()
        local widget
        local widget_tab
        --- @type table<integer, boolean>
        local baseline_tabs

        before_each(function()
            baseline_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                baseline_tabs[tabpage] = true
            end
            vim.cmd("tabnew")
            widget_tab = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                if not baseline_tabs[tabpage] then
                    pcall(function()
                        vim.cmd(
                            "tabclose! "
                                .. vim.api.nvim_tabpage_get_number(tabpage)
                        )
                    end)
                end
            end
        end)

        it("returns nil for a widget that has never been shown", function()
            assert.is_nil(widget:get_visible_tab_id())
        end)

        it("returns the tabpage the widget is shown in", function()
            widget:show({ focus_prompt = false })

            assert.equal(widget:get_visible_tab_id(), widget_tab)
        end)

        it("returns the widget's own tab, not the current one", function()
            widget:show({ focus_prompt = false })

            vim.cmd("tabnew")
            local other_tab = vim.api.nvim_get_current_tabpage()
            assert.is_not_nil(widget:get_visible_tab_id())
            assert.equal(widget:get_visible_tab_id(), widget_tab)
            assert.is_not.equal(widget:get_visible_tab_id(), other_tab)

            vim.cmd("tabclose")
        end)

        it("returns nil after hide, despite the hidden float", function()
            widget:show({ focus_prompt = false })
            widget:hide()

            -- Float holds the chat buffer for ADR 0001 fold anchoring, but sits
            -- outside win_nrs and must not count as visible.
            assert.is_not_nil(widget._hidden_chat_winid)
            assert.is_nil(widget:get_visible_tab_id())
        end)

        it("agrees with is_open across never-shown, shown, hidden", function()
            widget:show({ focus_prompt = false })
            assert.is_true(widget:is_open())

            widget:hide()
            assert.is_false(widget:is_open())
        end)

        -- ADR 0008: `show` re-renders IN PLACE. A bare `show` from another tab
        -- splits from the current window, leaving an untracked second copy in
        -- the tab the user is looking at.
        it(
            "show() re-renders in the widget's own tab, not the current one",
            function()
                widget:show({ focus_prompt = false })
                local before = vim.tbl_values(widget.win_nrs)
                assert.is_true(#before > 0)

                vim.cmd("tabnew")
                local other_tab = vim.api.nvim_get_current_tabpage()
                local other_wins = #vim.api.nvim_tabpage_list_wins(other_tab)

                widget:show({ focus_prompt = false })

                assert.equal(widget_tab, widget:get_visible_tab_id())
                for _, winid in pairs(widget.win_nrs) do
                    assert.equal(
                        widget_tab,
                        vim.api.nvim_win_get_tabpage(winid)
                    )
                end
                assert.equal(
                    other_wins,
                    #vim.api.nvim_tabpage_list_wins(other_tab)
                )
                assert.equal(other_tab, vim.api.nvim_get_current_tabpage())

                vim.cmd("tabclose")
            end
        )

        it("rerender() from another tab keeps the widget in place", function()
            widget:show({ focus_prompt = false })

            vim.cmd("tabnew")
            local other_tab = vim.api.nvim_get_current_tabpage()
            local other_wins = #vim.api.nvim_tabpage_list_wins(other_tab)

            widget:rerender()

            assert.equal(widget_tab, widget:get_visible_tab_id())
            assert.equal(other_wins, #vim.api.nvim_tabpage_list_wins(other_tab))

            vim.cmd("tabclose")
        end)

        -- ADR 0008 names `rerender` an in-place `show` caller that cannot break
        -- "at most one visible widget per tabpage"; the nil-tab early return is
        -- the whole proof. Without it, a `plan` update from a hidden session
        -- surfaced a second widget.
        it("rerender() is a no-op for a hidden widget", function()
            widget:show({ focus_prompt = false })
            widget:hide()

            vim.cmd("tabnew")
            local other_tab = vim.api.nvim_get_current_tabpage()
            local other_wins = #vim.api.nvim_tabpage_list_wins(other_tab)

            widget:rerender()

            assert.is_nil(widget:get_visible_tab_id())
            assert.is_false(widget:is_open())
            assert.equal(other_wins, #vim.api.nvim_tabpage_list_wins(other_tab))

            vim.cmd("tabclose")
        end)
    end)

    describe("widget registry integration", function()
        local WidgetRegistry = require("agentic.ui.widget_registry")
        local widget

        before_each(function()
            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(on_submit_spy --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("registers every buffer with the widget registry", function()
            for _, bufnr in pairs(widget.buf_nrs) do
                assert.equal(WidgetRegistry.get(bufnr), widget)
            end
        end)

        it("unregisters its buffers on destroy", function()
            local bufnrs = vim.tbl_values(widget.buf_nrs)
            assert.is_true(#bufnrs > 0)

            widget:destroy()
            widget = nil

            for _, bufnr in ipairs(bufnrs) do
                assert.is_nil(WidgetRegistry.get(bufnr))
            end
        end)
    end)

    describe("find_first_non_widget_window", function()
        local widget
        local widget2
        local notify_stub
        --- @type table<integer, boolean>
        local baseline_tabs

        before_each(function()
            baseline_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                baseline_tabs[tabpage] = true
            end
            vim.cmd("tabnew")
            notify_stub = spy.stub(Logger, "notify")
            widget = ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        after_each(function()
            for _, w in ipairs({ widget, widget2 }) do
                if w then
                    pcall(function()
                        w:destroy()
                    end)
                end
            end
            widget = nil
            widget2 = nil
            notify_stub:revert()
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                if not baseline_tabs[tabpage] then
                    vim.cmd(
                        "tabclose! " .. vim.api.nvim_tabpage_get_number(tabpage)
                    )
                end
            end
        end)

        it("returns nil for a hidden widget", function()
            assert.is_nil(widget:find_first_non_widget_window())

            widget:show({ focus_prompt = false })
            assert.is_not_nil(widget:find_first_non_widget_window())

            widget:hide()
            assert.is_nil(widget:find_first_non_widget_window())
        end)

        it("never returns another widget's window in the same tab", function()
            widget:show({ focus_prompt = false })
            widget2 = ChatWidget:new(spy.new(function() end) --[[@as function]])
            widget2:show({ focus_prompt = false })

            local own = widget:find_first_non_widget_window()
            local other = widget2:find_first_non_widget_window()
            assert.is_not_nil(own)
            assert.is_not_nil(other)

            for _, pair in ipairs({
                { own, widget2.win_nrs },
                { own, widget.win_nrs },
                { other, widget.win_nrs },
                { other, widget2.win_nrs },
            }) do
                for _, winid in pairs(pair[2]) do
                    assert.is_not.equal(pair[1], winid)
                end
            end
        end)

        it("does not fall back to an eligible window in another tab", function()
            widget:show({ focus_prompt = false })
            local widget_tab = widget:get_visible_tab_id()

            for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(widget_tab)) do
                if not vim.w[winid].agentic_bufnr then
                    pcall(vim.api.nvim_win_close, winid, true)
                end
            end

            -- Another tab holds an eligible editor window. A global
            -- `nvim_list_wins()` enumeration hands it back, and `hide`/`destroy`
            -- then closes the widget's own tab out from under the user.
            vim.cmd("tabnew")
            local other_tab = vim.api.nvim_get_current_tabpage()
            local other_win = vim.api.nvim_get_current_win()

            assert.is_nil(widget:find_first_non_widget_window())

            local fallback = widget:open_editor_window()
            assert.is_not_nil(fallback)
            ---@cast fallback integer
            assert.is_not.equal(other_win, fallback)
            assert.equal(widget_tab, vim.api.nvim_win_get_tabpage(fallback))
            assert.equal(other_tab, vim.api.nvim_get_current_tabpage())
        end)

        it(
            "never returns a window showing a registered widget buffer it did not create",
            function()
                widget:show({ focus_prompt = false })

                widget2 =
                    ChatWidget:new(spy.new(function() end) --[[@as function]])

                local fallback = widget:find_first_non_widget_window()
                assert.is_not_nil(fallback)
                ---@cast fallback integer

                -- A window no widget created carries no `vim.w.agentic_bufnr`,
                -- so the registry lookup is the only axis that rejects it.
                -- Returning it ejects a redirected file into another
                -- session's panel buffer.
                vim.api.nvim_win_set_buf(fallback, widget2.buf_nrs.chat)
                assert.is_nil(vim.w[fallback].agentic_bufnr)

                assert.is_not.equal(
                    fallback,
                    widget:find_first_non_widget_window()
                )
            end
        )
    end)

    describe("hide across tabs", function()
        local widget
        local notify_stub

        before_each(function()
            vim.cmd("tabnew")
            notify_stub = spy.stub(Logger, "notify")
            widget = ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            notify_stub:revert()
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it(
            "keeps the chat buffer attached when no fallback window can be created",
            function()
                widget:show({ focus_prompt = false })

                -- ADR 0001: once hidden, the float is the chat buffer's only
                -- window. Losing it loses the fold anchor.
                widget.find_first_non_widget_window = function()
                    return nil
                end
                widget.open_editor_window = function()
                    return nil
                end

                widget:hide()

                assert.is_true(#vim.fn.win_findbuf(widget.buf_nrs.chat) > 0)
                assert.is_not_nil(widget._hidden_chat_winid)
                assert.spy(notify_stub).was.called(1)
            end
        )

        it("does not report a fallback failure for a hidden widget", function()
            widget:show({ focus_prompt = false })
            widget:hide()

            -- A hidden widget owns no windows: nothing to keep the tab alive,
            -- no fallback to create.
            widget:hide()

            assert.equal(0, notify_stub.call_count)
        end)

        it(
            "creates the fallback window in the widget's tab, not the current one",
            function()
                widget:show({ focus_prompt = false })
                local widget_tab = widget:get_visible_tab_id()

                -- Leave only widget windows in the widget's tab
                for _, winid in
                    ipairs(vim.api.nvim_tabpage_list_wins(widget_tab))
                do
                    if not vim.w[winid].agentic_bufnr then
                        pcall(vim.api.nvim_win_close, winid, true)
                    end
                end

                vim.cmd("tabnew")
                local other_tab = vim.api.nvim_get_current_tabpage()

                widget:hide()

                assert.equal(other_tab, vim.api.nvim_get_current_tabpage())
                assert.is_true(#vim.api.nvim_tabpage_list_wins(widget_tab) > 0)
                assert.equal(0, notify_stub.call_count)

                vim.cmd("tabclose")
            end
        )
    end)

    describe("destroy", function()
        local widget

        before_each(function()
            vim.cmd("tabnew")
            widget = ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it(
            "closes the windows and deletes the buffers of a visible widget",
            function()
                widget:show({ focus_prompt = false })
                local chat_win = widget.win_nrs.chat
                local input_win = widget.win_nrs.input
                local bufnrs = vim.tbl_values(widget.buf_nrs)

                widget:destroy()
                widget = nil

                assert.is_false(vim.api.nvim_win_is_valid(chat_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                for _, bufnr in ipairs(bufnrs) do
                    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
                end
            end
        )

        it("deletes the buffers of a hidden widget without raising", function()
            local bufnrs = vim.tbl_values(widget.buf_nrs)

            assert.has_no_errors(function()
                widget:destroy()
            end)
            widget = nil

            for _, bufnr in ipairs(bufnrs) do
                assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            end
        end)

        -- Destroying a session visible in ANOTHER tab is reachable from
        -- `Agentic.destroy_session` and `SessionRestore`, both resolving through
        -- `_most_recent`. Closing that tab's last windows invalidates the
        -- tabpage silently: the user loses a tab with no error.
        it(
            "keeps the tabpage alive when the widget holds its only windows",
            function()
                widget:show({ focus_prompt = false })
                local widget_tab = widget:get_visible_tab_id()

                for _, winid in
                    ipairs(vim.api.nvim_tabpage_list_wins(widget_tab))
                do
                    if not vim.w[winid].agentic_bufnr then
                        pcall(vim.api.nvim_win_close, winid, true)
                    end
                end

                vim.cmd("tabnew")
                local other_tab = vim.api.nvim_get_current_tabpage()

                widget:destroy()
                widget = nil

                assert.is_true(vim.api.nvim_tabpage_is_valid(widget_tab))
                assert.equal(other_tab, vim.api.nvim_get_current_tabpage())

                vim.cmd("tabclose")
            end
        )
    end)

    describe("input header suffix", function()
        local widget

        before_each(function()
            vim.cmd("tabnew")
            widget = ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        after_each(function()
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("seeds normal-mode hints at construction time", function()
            local headers =
                WindowDecoration.get_headers_state(widget.buf_nrs.input)
            assert.equal(
                "submit: <CR> | change mode: <S-Tab>",
                headers.input.suffix
            )
            -- Identity, not deep equality: the accessor must hand back the
            -- widget's OWN table so caller mutations persist without a
            -- write-back. `assert.equal` deep-compares and passes against a
            -- copy; only `==` pins ownership.
            assert.is_true(headers == widget.headers)
        end)
    end)

    describe("header state ownership", function()
        local widget_a
        local widget_b
        --- @type table<integer, boolean>
        local baseline_tabs
        local unowned_bufnr

        before_each(function()
            baseline_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                baseline_tabs[tabpage] = true
            end
            unowned_bufnr = nil
            vim.cmd("tabnew")
            widget_a =
                ChatWidget:new(spy.new(function() end) --[[@as function]])
            widget_b =
                ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        -- Closes down to the pre-case tab count, not one fixed `tabclose`: the
        -- hide/show case opens a SECOND tab, and a red assertion there used to
        -- skip its trailing cleanup and leak a tabpage into every later case.
        after_each(function()
            for _, widget in ipairs({ widget_a, widget_b }) do
                pcall(function()
                    widget:destroy()
                end)
            end
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                if not baseline_tabs[tabpage] then
                    vim.cmd(
                        "tabclose! " .. vim.api.nvim_tabpage_get_number(tabpage)
                    )
                end
            end
            if unowned_bufnr and vim.api.nvim_buf_is_valid(unowned_bufnr) then
                vim.api.nvim_buf_delete(unowned_bufnr, { force = true })
            end
        end)

        it("keeps each widget's header context independent", function()
            local headers_a =
                WindowDecoration.get_headers_state(widget_a.buf_nrs.chat)
            headers_a.chat.context = "context A"

            local headers_b =
                WindowDecoration.get_headers_state(widget_b.buf_nrs.chat)

            assert.equal(
                "context A",
                WindowDecoration.get_headers_state(widget_a.buf_nrs.chat).chat.context
            )
            assert.is_nil(headers_b.chat.context)
        end)

        it(
            "keeps header context across hide and show in another tab",
            function()
                widget_a:show()
                WindowDecoration.get_headers_state(widget_a.buf_nrs.input).input.context =
                    "3 files"
                widget_a:hide()

                vim.cmd("tabnew")
                widget_a:show()

                assert.equal(
                    "3 files",
                    WindowDecoration.get_headers_state(widget_a.buf_nrs.input).input.context
                )
            end
        )

        it(
            "hands out a fresh default table per call when no widget owns the bufnr",
            function()
                unowned_bufnr = vim.api.nvim_create_buf(false, true)

                -- The owned path returns the widget's own table, which callers
                -- MUST mutate in place. The unowned fallback cannot: each call
                -- deep-copies the module defaults, so this mutation is
                -- discarded rather than shared with the next caller.
                WindowDecoration.get_headers_state(unowned_bufnr).chat.context =
                    "leaked"
                local second = WindowDecoration.get_headers_state(unowned_bufnr)

                assert.is_nil(second.chat.context)
            end
        )
    end)

    describe("_render_dynamic_headers", function()
        local widget
        local original_headers

        before_each(function()
            original_headers = Config.headers
            vim.cmd("tabnew")
            widget = ChatWidget:new(spy.new(function() end) --[[@as function]])
        end)

        after_each(function()
            Config.headers = original_headers
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it(
            "refreshes chat and input with default (empty) Config.headers",
            function()
                Config.headers = {}
                local render_spy = spy.new(function() end)
                widget.render_header = render_spy

                widget:_render_dynamic_headers()

                local panels = {}
                for _, call in ipairs(render_spy.calls) do
                    panels[call[2]] = true
                end
                assert.is_true(panels.chat)
                assert.is_true(panels.input)
            end
        )

        it("refreshes a user-function panel too", function()
            Config.headers = {
                files = function(parts)
                    return parts.title
                end,
            }
            local render_spy = spy.new(function() end)
            widget.render_header = render_spy

            widget:_render_dynamic_headers()

            local panels = {}
            for _, call in ipairs(render_spy.calls) do
                panels[call[2]] = true
            end
            assert.is_true(panels.files)
        end)
    end)
end)

-- Child process: `rotate_layout` restores the cursor inside `vim.schedule`;
-- flushing in-process pumps mini.test's own queue (measured: a later file's case
-- ran inside this one). `references/async-tests.md` prescribes a child here.
local Child = require("tests.helpers.child")

describe(
    "agentic.ui.ChatWidget rotate_layout cursor restore (child)",
    function()
        local child = Child.new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("never restores the cursor into the hidden chat float", function()
            -- Rotating from the chat window makes the chat buffer "previous",
            -- and `hide` leaves it attached only to the hidden float (ADR 0001).
            -- The replaced lookup returned that float, landing the cursor in a
            -- window the user cannot see.
            child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })
            vim.api.nvim_set_current_win(_G.widget.win_nrs.chat)
            _G.widget:rotate_layout({ "right", "bottom" })
        ]])

            child.flush()
            vim.uv.sleep(50)
            child.flush()

            -- The exact window, not "some visible one": asserting only
            -- focusable/hide passes with cursor restoration deleted entirely,
            -- since a bare `show` already leaves the cursor in a real window.
            assert.equal(
                child.lua_get("_G.widget.win_nrs.chat"),
                child.lua_get("vim.api.nvim_get_current_win()")
            )

            local config = child.lua_get(
                "vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())"
            )

            assert.is_true(config.focusable)
            assert.is_falsy(config.hide)
        end)

        it(
            "drops cursor restoration after the widget becomes hidden",
            function()
                child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })

            _G.widget:rotate_layout({ "right", "bottom" })
            _G.widget:hide()

            vim.cmd("tabnew")
            _G.safe_tab = vim.api.nvim_get_current_tabpage()
            _G.safe_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(_G.safe_win, vim.api.nvim_create_buf(true, false))
        ]])

                child.flush()

                assert.equal(
                    child.lua_get("_G.safe_tab"),
                    child.lua_get("vim.api.nvim_get_current_tabpage()")
                )
                assert.equal(
                    child.lua_get("_G.safe_win"),
                    child.lua_get("vim.api.nvim_get_current_win()")
                )
            end
        )

        it(
            "does not restore insert mode without the previous window",
            function()
                child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })

            _G.previous_win = _G.widget:find_first_non_widget_window()
            _G.previous_buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(_G.previous_win, _G.previous_buf)
            vim.api.nvim_set_current_win(_G.previous_win)

            _G.rotate_without_previous_window = function()
                _G.widget:rotate_layout({ "right", "bottom" })
                vim.api.nvim_win_set_buf(
                    _G.previous_win,
                    vim.api.nvim_create_buf(true, false)
                )
                _G.safe_win = vim.api.nvim_get_current_win()
            end
            vim.api.nvim_buf_set_keymap(
                _G.previous_buf,
                "i",
                "<F5>",
                "<Cmd>lua _G.rotate_without_previous_window()<CR>",
                { noremap = true }
            )
        ]])

                child.type_keys("i", "<F5>")
                child.flush()

                assert.equal("n", child.fn.mode())
                assert.equal(
                    child.lua_get("_G.safe_win"),
                    child.lua_get("vim.api.nvim_get_current_win()")
                )
            end
        )
    end
)

-- Child process: WinClosed defers `hide` through `vim.schedule`; flushing
-- in-process pumps mini.test's own queue.
describe("agentic.ui.ChatWidget WinClosed deferred hide (child)", function()
    local child = Child.new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("keeps a widget-only tab alive when the chat window closes", function()
        -- `WinClosed` invalidates `win_nrs.chat` before the scheduled `hide`, so
        -- `get_visible_tab_id()` answers nil and `_ensure_fallback_window`
        -- returns early. `WidgetLayout.close` then takes the remaining windows
        -- down with the tabpage.
        child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            vim.cmd("tabnew")
            _G.widget_tab = vim.api.nvim_get_current_tabpage()
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })

            for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(_G.widget_tab)) do
                if not vim.w[winid].agentic_bufnr then
                    pcall(vim.api.nvim_win_close, winid, true)
                end
            end

            vim.api.nvim_win_close(_G.widget.win_nrs.chat, true)
        ]])

        child.flush()

        assert.is_true(
            child.lua_get("vim.api.nvim_tabpage_is_valid(_G.widget_tab)")
        )
        assert.is_true(
            child.lua_get("#vim.api.nvim_tabpage_list_wins(_G.widget_tab) > 0")
        )
    end)

    it(
        "keeps replacement windows after closing a cached cross-tab window",
        function()
            child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })
            _G.widget_tab = _G.widget:get_visible_tab_id()

            vim.cmd("tabnew")
            _G.stale_input = vim.api.nvim_open_win(
                _G.widget.buf_nrs.input,
                false,
                { split = "right", win = -1 }
            )
            _G.widget.win_nrs.input = _G.stale_input

            _G.widget:show({ focus_prompt = false })
            _G.replacement_chat = _G.widget.win_nrs.chat
            _G.replacement_input = _G.widget.win_nrs.input
        ]])

            child.flush()

            assert.is_false(
                child.lua_get("vim.api.nvim_win_is_valid(_G.stale_input)")
            )
            assert.equal(
                child.lua_get("_G.replacement_chat"),
                child.lua_get("_G.widget.win_nrs.chat")
            )
            assert.equal(
                child.lua_get("_G.replacement_input"),
                child.lua_get("_G.widget.win_nrs.input")
            )
            assert.is_true(
                child.lua_get("vim.api.nvim_win_is_valid(_G.replacement_chat)")
            )
            assert.is_true(
                child.lua_get("vim.api.nvim_win_is_valid(_G.replacement_input)")
            )
            assert.equal(
                child.lua_get("_G.widget_tab"),
                child.lua_get(
                    "vim.api.nvim_win_get_tabpage(_G.replacement_chat)"
                )
            )
        end
    )
end)

describe("agentic.ui.ChatWidget WinClosed size memory (child)", function()
    local child = Child.new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("keeps a manual width when the user closes the chat window", function()
        -- `:q` on the chat window reaches `hide` only through `vim.schedule`, by
        -- which time the window is gone and nothing is left to measure.
        child.lua([[
            local ChatWidget = require("agentic.ui.chat_widget")
            local BufHelpers = require("agentic.utils.buf_helpers")
            _G.widget = ChatWidget:new(function() return true end)
            _G.widget:show({ focus_prompt = false })
            _G.target_width =
                vim.api.nvim_win_get_width(_G.widget.win_nrs.chat) + 5
            BufHelpers.win_set_width(_G.widget.win_nrs.chat, _G.target_width)
            vim.api.nvim_win_close(_G.widget.win_nrs.chat, true)
        ]])

        child.flush()

        child.lua([[ _G.widget:show({ focus_prompt = false }) ]])

        assert.equal(
            child.lua_get("_G.target_width"),
            child.lua_get("vim.api.nvim_win_get_width(_G.widget.win_nrs.chat)")
        )
    end)
end)
