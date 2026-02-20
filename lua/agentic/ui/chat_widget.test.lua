local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

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
            Config.windows.position = "right"

            widget:rotate_layout()

            assert.equal("bottom", Config.windows.position)
        end)

        it("uses default layouts when empty array provided", function()
            Config.windows.position = "right"

            widget:rotate_layout({})

            assert.equal("bottom", Config.windows.position)
        end)

        it(
            "stays on same layout and warns when only one is provided",
            function()
                Config.windows.position = "bottom"

                widget:rotate_layout({ "bottom" })

                assert.equal("bottom", Config.windows.position)
                assert.spy(notify_stub).was.called(1)
                local msg = notify_stub.calls[1][1]
                assert.is_true(msg:find("Only one layout") ~= nil)
            end
        )

        it("rotates through all layouts in order", function()
            local layouts = { "right", "bottom", "left" }

            Config.windows.position = "right"
            widget:rotate_layout(layouts)
            assert.equal("bottom", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("left", Config.windows.position)

            widget:rotate_layout(layouts)
            assert.equal("right", Config.windows.position)
        end)

        it("falls back to first layout when current is not in list", function()
            Config.windows.position = "bottom"

            widget:rotate_layout({ "right", "left" })

            assert.equal("right", Config.windows.position)
        end)

        it("calls show with focus_prompt false", function()
            widget:rotate_layout()

            assert.spy(show_stub).was.called(1)
            local call_args = show_stub.calls[1]
            -- call_args[1] is self, call_args[2] is the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)
    end)
end)
