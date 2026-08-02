local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetRegistry = require("agentic.ui.widget_registry")
local BufHelpers = require("agentic.utils.buf_helpers")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    --- Helper to populate a dynamic buffer with content
    --- @param widget agentic.ui.ChatWidget
    --- @param name string
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    -- Tests that behave identically regardless of layout position
    for _, position in ipairs({ "right", "left", "bottom" }) do
        -- Bottom layout uses 2 to avoid touching the screen edge
        local padding = position == "bottom" and 2 or 1

        describe(string.format("(%s layout)", position), function()
            local tab_page_id
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = position

                vim.cmd("tabnew")
                tab_page_id = vim.api.nvim_get_current_tabpage()

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    tab_page_id,
                    on_submit_spy --[[@as function]]
                )
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
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.chat)
                )
                assert.equal(
                    tab_page_id,
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
                                tab_page_id,
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

                    local tmpfile = vim.fn.tempname() .. ".lua"
                    vim.fn.writefile({ "-- test" }, tmpfile)

                    vim.cmd("edit " .. vim.fn.fnameescape(tmpfile))

                    -- Chat window does not contain the temp file
                    -- (guard either restored chat_buf or replaced it with a
                    -- fresh scratch buffer to keep the window clean)
                    local buf_in_chat = vim.api.nvim_win_get_buf(chat_win)
                    local name_in_chat = vim.api.nvim_buf_get_name(buf_in_chat)
                    local resolved_in_chat = vim.fn.resolve(name_in_chat)
                    local resolved_tmpfile = vim.fn.resolve(tmpfile)
                    assert.are_not.equal(resolved_tmpfile, resolved_in_chat)

                    -- The temp file is open in some non-widget window on the same tabpage
                    local found_in_non_widget = false
                    local all_wins = vim.api.nvim_tabpage_list_wins(tab_page_id)
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
                    os.remove(tmpfile)
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

                        -- Swap: put input_buf into chat_win (a widget buffer,
                        -- but the WRONG one for this window).
                        vim.api.nvim_set_current_win(chat_win)
                        vim.api.nvim_win_set_buf(chat_win, input_buf)

                        -- Guard should have restored the correct buffer
                        assert.equal(
                            chat_buf,
                            vim.api.nvim_win_get_buf(chat_win)
                        )
                        -- Input window should be unaffected
                        assert.equal(
                            input_buf,
                            vim.api.nvim_win_get_buf(input_win)
                        )
                    end
                )

                it("guard is cleaned up after destroy", function()
                    widget:show()
                    widget:destroy()

                    assert.is_nil(widget._guard_augroup)

                    -- Prevent double-destroy in after_each
                    widget = nil
                end)

                it(
                    "skips floating windows in find_first_non_widget_window",
                    function()
                        widget:show()

                        -- Close all non-widget windows on the tabpage
                        local all_wins =
                            vim.api.nvim_tabpage_list_wins(tab_page_id)
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

                        -- Create a floating window
                        local float_buf = vim.api.nvim_create_buf(false, true)
                        local float_win =
                            vim.api.nvim_open_win(float_buf, false, {
                                relative = "editor",
                                width = 10,
                                height = 3,
                                row = 1,
                                col = 1,
                            })

                        local result = widget:find_first_non_widget_window()
                        assert.is_nil(result)
                        -- Clean up floating window and buffer
                        vim.api.nvim_win_close(float_win, true)
                        vim.api.nvim_buf_delete(float_buf, { force = true })
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
                -- _closing is set synchronously by the WinClosed handler
                -- and only reset inside vim.schedule (which doesn't run
                -- in same-process tests). So _closing == true means the
                -- handler matched and scheduled hide().

                it(
                    "close_optional_window does not trigger WinClosed handler",
                    function()
                        fill_buffer(widget, "code", { "line1" })
                        fill_buffer(widget, "files", { "file.lua" })

                        widget:show()
                        assert.is_not_nil(widget.win_nrs.code)
                        assert.is_not_nil(widget.win_nrs.files)

                        widget:close_optional_window("code")

                        -- Code window is gone
                        assert.is_nil(widget.win_nrs.code)
                        -- WinClosed handler did NOT schedule hide()
                        assert.is_false(widget._closing)
                        -- Core windows still exist
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

    -- Right and left layouts behave identically, only split direction differs
    for _, side in ipairs({ "right", "left" }) do
        describe(string.format("(%s layout) specific", side), function()
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = side

                vim.cmd("tabnew")

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    vim.api.nvim_get_current_tabpage(),
                    on_submit_spy --[[@as function]]
                )
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

                -- Input row should be greater than chat row (below)
                assert.is_true(input_pos[1] > chat_pos[1])
                -- Same column position
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
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )
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

            -- Same row (horizontal split)
            assert.equal(chat_pos[1], input_pos[1])
            -- Input column should be greater than chat column (to the right)
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

                -- Allow +-1 rounding tolerance
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
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )

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
            -- call_args[1] is self, call_args[2] is the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)

        it("does not mutate Config.windows.position", function()
            widget:rotate_layout()

            assert.equal("right", Config.windows.position)
            assert.equal("bottom", widget.current_position)
        end)

        it("two widgets rotate independently", function()
            local on_submit_spy2 = spy.new(function() end)
            widget2 = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy2 --[[@as function]]
            )
            show_stub2 = spy.stub(widget2, "show")

            -- Both start at "right" (Config default)
            assert.equal("right", widget.current_position)
            assert.equal("right", widget2.current_position)

            -- Rotate widget 1
            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("right", widget2.current_position)

            -- Rotate widget 2
            widget2:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("bottom", widget2.current_position)

            -- Rotate widget 1 again
            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("left", widget.current_position)
            assert.equal("bottom", widget2.current_position)
        end)
    end)

    describe("hidden chat window lifecycle", function()
        local widget
        local tab_page_id

        before_each(function()
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget =
                ChatWidget:new(tab_page_id, on_submit_spy --[[@as function]])
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

    describe("widget buffer ownership", function()
        local widget
        --- @type any
        local extra_widget
        local baseline_tabs
        local cleanup_buffers
        --- @type TestStub|nil
        local find_stub
        --- @type TestStub|nil
        local unregister_stub
        --- @type TestStub|nil
        local delete_stub

        before_each(function()
            baseline_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                baseline_tabs[tabpage] = true
            end
            cleanup_buffers = {}
            find_stub = nil
            unregister_stub = nil
            delete_stub = nil

            vim.cmd("tabnew")
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                spy.new(function() end) --[[@as function]]
            )
        end)

        after_each(function()
            if delete_stub then
                delete_stub:revert()
            end
            if unregister_stub then
                unregister_stub:revert()
            end
            if find_stub then
                find_stub:revert()
            end
            if extra_widget then
                WidgetRegistry.unregister(extra_widget)
                extra_widget = nil
            end
            if widget then
                pcall(function()
                    widget:destroy()
                end)
                widget = nil
            end
            for _, bufnr in ipairs(cleanup_buffers) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
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

        it("registers every buffer after initialization", function()
            for _, bufnr in pairs(widget.buf_nrs) do
                assert.equal(widget, WidgetRegistry.get(bufnr))
            end
        end)

        it(
            "never selects another registered widget window as fallback",
            function()
                widget:show({ focus_prompt = false })

                local foreign_buf = vim.api.nvim_create_buf(false, true)
                cleanup_buffers[#cleanup_buffers + 1] = foreign_buf
                local foreign_win = vim.api.nvim_open_win(foreign_buf, false, {
                    split = "left",
                    win = widget.win_nrs.chat,
                })
                extra_widget = {
                    buf_nrs = { chat = foreign_buf },
                    win_nrs = { chat = foreign_win },
                }
                WidgetRegistry.register(extra_widget)

                local editor_win = widget:find_first_non_widget_window()
                assert.is_not_nil(editor_win)
                --- @cast editor_win integer
                vim.api.nvim_win_close(editor_win, true)

                assert.is_nil(widget:find_first_non_widget_window())
            end
        )

        it(
            "never selects an ordinary window showing a registered widget buffer",
            function()
                widget:show({ focus_prompt = false })

                local foreign_buf = vim.api.nvim_create_buf(false, true)
                cleanup_buffers[#cleanup_buffers + 1] = foreign_buf
                extra_widget =
                    { buf_nrs = { chat = foreign_buf }, win_nrs = {} }
                WidgetRegistry.register(extra_widget)
                vim.api.nvim_open_win(foreign_buf, false, {
                    split = "left",
                    win = widget.win_nrs.chat,
                })

                local editor_win = widget:find_first_non_widget_window()
                assert.is_not_nil(editor_win)
                --- @cast editor_win integer
                vim.api.nvim_win_close(editor_win, true)

                assert.is_nil(widget:find_first_non_widget_window())
            end
        )

        it(
            "resolves fallback before unregistering and deleting buffers",
            function()
                widget:show({ focus_prompt = false })

                local events = {}
                local original_find = widget.find_first_non_widget_window
                local original_unregister = WidgetRegistry.unregister
                local original_delete = vim.api.nvim_buf_delete
                find_stub = spy.stub(widget, "find_first_non_widget_window")
                find_stub:invokes(function(self)
                    events[#events + 1] = "fallback"
                    return original_find(self)
                end)
                unregister_stub = spy.stub(WidgetRegistry, "unregister")
                unregister_stub:invokes(function(owner)
                    events[#events + 1] = "unregister"
                    return original_unregister(owner)
                end)
                delete_stub = spy.stub(vim.api, "nvim_buf_delete")
                delete_stub:invokes(function(bufnr, opts)
                    events[#events + 1] = "delete"
                    return original_delete(bufnr, opts)
                end)

                widget:destroy()
                widget = nil

                delete_stub:revert()
                delete_stub = nil
                unregister_stub:revert()
                unregister_stub = nil
                find_stub:revert()
                find_stub = nil

                assert.equal("fallback", events[1])
                assert.equal("unregister", events[2])
                assert.equal("delete", events[3])
            end
        )
    end)

    describe("input header suffix", function()
        local tab_page_id
        local widget

        before_each(function()
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()
            widget = ChatWidget:new(
                tab_page_id,
                spy.new(function() end) --[[@as function]]
            )
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
            local headers = WindowDecoration.get_headers_state(tab_page_id)
            assert.equal(
                "submit: <CR> | change mode: <S-Tab>",
                headers.input.suffix
            )
        end)
    end)

    describe("_render_dynamic_headers", function()
        local tab_page_id
        local widget
        local original_headers

        before_each(function()
            original_headers = Config.headers
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()
            widget = ChatWidget:new(
                tab_page_id,
                spy.new(function() end) --[[@as function]]
            )
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

describe("agentic.ui.ChatWidget deferred window guards", function()
    local ChatWidget = require("agentic.ui.chat_widget")
    local schedule_stub
    local scheduled
    local saved_move_cursor
    local base_tabs
    local base_bufs
    local created_widgets

    --- @return agentic.ui.ChatWidget widget
    local function create_widget()
        local widget = ChatWidget:new(
            vim.api.nvim_get_current_tabpage(),
            spy.new(function() end) --[[@as function]]
        )
        created_widgets[#created_widgets + 1] = widget
        return widget
    end

    before_each(function()
        base_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tabpage] = true
        end
        base_bufs = {}
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            base_bufs[bufnr] = true
        end
        created_widgets = {}
        saved_move_cursor = Config.settings.move_cursor_to_chat_on_submit
        Config.settings.move_cursor_to_chat_on_submit = true
        scheduled = nil
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            scheduled = callback
        end)
    end)

    after_each(function()
        for _, widget in ipairs(created_widgets) do
            pcall(function()
                widget:destroy()
            end)
        end
        schedule_stub:revert()
        Config.settings.move_cursor_to_chat_on_submit = saved_move_cursor
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tabs[tabpage] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
        local extra_bufs = 0
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] then
                extra_bufs = extra_bufs + 1
            end
        end
        assert.equal(0, extra_bufs)
    end)

    it("focuses a rebuilt panel instead of its captured handle", function()
        vim.cmd("tabnew")
        local tabpage = vim.api.nvim_get_current_tabpage()
        local old_win = vim.api.nvim_get_current_win()
        local replacement_buf = vim.api.nvim_create_buf(false, true)
        local replacement = vim.api.nvim_open_win(replacement_buf, false, {
            split = "right",
            win = old_win,
        })
        local widget = {
            tab_page_id = tabpage,
            win_nrs = { chat = old_win },
        }

        ChatWidget.move_cursor_to(widget, old_win)
        widget.win_nrs.chat = replacement
        vim.api.nvim_win_close(old_win, true)
        local bystander_buf = vim.api.nvim_create_buf(false, true)
        local bystander = vim.api.nvim_open_win(bystander_buf, true, {
            split = "below",
            win = replacement,
        })
        assert.equal(bystander, vim.api.nvim_get_current_win())
        scheduled()

        assert.equal(replacement, vim.api.nvim_get_current_win())
    end)

    it("ignores a hidden destination window", function()
        vim.cmd("tabnew")
        local current = vim.api.nvim_get_current_win()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local hidden = vim.api.nvim_open_win(bufnr, false, {
            relative = "editor",
            row = 0,
            col = 0,
            width = 10,
            height = 2,
            hide = true,
            focusable = false,
        })
        local widget = { win_nrs = { chat = hidden } }

        ChatWidget.move_cursor_to(widget, hidden)

        assert.has_no_errors(scheduled)
        assert.equal(current, vim.api.nvim_get_current_win())
        pcall(vim.api.nvim_win_close, hidden, true)
    end)

    it("ignores a stale-valid handle whose tabpage is gone", function()
        vim.cmd("tabnew")
        local target = vim.api.nvim_get_current_win()
        local widget = { win_nrs = { chat = target } }
        local usable_stub = spy.stub(BufHelpers, "is_win_usable")
        usable_stub:returns(false)
        local focus_stub = spy.stub(vim.api, "nvim_set_current_win")

        ChatWidget.move_cursor_to(widget, target)
        scheduled()

        local usable_called = usable_stub:called_with(target)
        local focus_count = focus_stub.call_count
        focus_stub:revert()
        usable_stub:revert()
        assert.is_true(usable_called)
        assert.equal(0, focus_count)
    end)

    it("restores rotation focus in the stored tabpage", function()
        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local previous_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, previous_buf)
        local old_win = vim.api.nvim_get_current_win()
        vim.cmd("split")
        local replacement = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(replacement, previous_buf)
        vim.api.nvim_set_current_win(old_win)
        local widget = {
            tab_page_id = owner_tab,
            current_position = "right",
            hide = function() end,
            show = function() end,
            is_open = function()
                return true
            end,
        }

        ChatWidget.rotate_layout(widget, { "right", "left" })
        vim.api.nvim_win_close(old_win, true)
        vim.cmd("tabnew")
        scheduled()

        assert.equal(replacement, vim.api.nvim_get_current_win())
    end)

    it("never restores rotation focus into the hidden chat float", function()
        vim.cmd("tabnew")
        local widget = create_widget()
        widget:show({ focus_prompt = false })
        vim.api.nvim_set_current_win(widget.win_nrs.chat)

        widget:rotate_layout({ "right", "bottom" })
        scheduled()

        assert.equal(widget.win_nrs.chat, vim.api.nvim_get_current_win())
        local config =
            vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
        assert.is_true(config.focusable)
        assert.is_falsy(config.hide)
    end)

    it("drops rotation focus restoration after the widget hides", function()
        vim.cmd("tabnew")
        local widget = create_widget()
        widget:show({ focus_prompt = false })

        widget:rotate_layout({ "right", "bottom" })
        widget:hide()
        vim.cmd("tabnew")
        local safe_tab = vim.api.nvim_get_current_tabpage()
        local safe_win = vim.api.nvim_get_current_win()
        scheduled()

        assert.equal(safe_tab, vim.api.nvim_get_current_tabpage())
        assert.equal(safe_win, vim.api.nvim_get_current_win())
    end)

    it("does not restore insert mode when the prior editor is gone", function()
        vim.cmd("tabnew")
        local mode_stub = spy.stub(vim.fn, "mode")
        mode_stub:returns("i")
        local startinsert_stub = spy.stub(vim.cmd, "startinsert")
        local old_win = vim.api.nvim_get_current_win()
        vim.cmd("split")
        local spare = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(old_win)
        local widget = {
            tab_page_id = vim.api.nvim_get_current_tabpage(),
            current_position = "right",
            hide = function() end,
            show = function() end,
            is_open = function()
                return true
            end,
        }

        ChatWidget.rotate_layout(widget, { "right", "left" })
        vim.api.nvim_win_close(old_win, true)
        vim.api.nvim_set_current_win(spare)
        scheduled()

        assert.spy(startinsert_stub).was.called(0)
        mode_stub:revert()
        startinsert_stub:revert()
    end)
end)
