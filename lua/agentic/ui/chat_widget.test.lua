---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    describe("show() and hide()", function()
        local tab_page_id
        local widget

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
            end
            vim.cmd("tabclose")
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

                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.input))
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

            -- Windows are closed
            assert.is_false(vim.api.nvim_win_is_valid(chat_win))
            assert.is_false(vim.api.nvim_win_is_valid(input_win))
            assert.is_nil(widget.win_nrs.chat)
            assert.is_nil(widget.win_nrs.input)
            assert.is_falsy(widget:is_open())

            -- Buffers are preserved
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

        describe("dynamic window creation based on buffer content", function()
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
                        local bufnr = widget.buf_nrs[tc.name]
                        vim.bo[bufnr].modifiable = true
                        vim.api.nvim_buf_set_lines(
                            bufnr,
                            0,
                            -1,
                            false,
                            tc.content
                        )

                        widget:show()

                        assert.is_true(
                            vim.api.nvim_win_is_valid(widget.win_nrs[tc.name])
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
            -- Setup: add content to all dynamic buffers
            for _, name in ipairs({ "files", "code", "todos" }) do
                vim.bo[widget.buf_nrs[name]].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs[name],
                    0,
                    -1,
                    false,
                    { "content" }
                )
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

        describe("dynamic window resizing", function()
            it("resizes window when content changes", function()
                vim.bo[widget.buf_nrs.code].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2", "line3" }
                )

                widget:show()
                local initial_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(4, initial_height) -- 3 lines + 1 padding

                -- Add more content
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    3,
                    3,
                    false,
                    { "line4", "line5", "line6", "line7" }
                )

                widget:show({ focus_prompt = false })

                local new_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(8, new_height) -- 7 lines + 1 padding
            end)

            it("caps window height at max_height", function()
                vim.bo[widget.buf_nrs.code].modifiable = true

                -- Add 23 lines (exceeds default max_height=15)
                local lines = {}
                for i = 1, 23 do
                    lines[i] = "line" .. i
                end
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    lines
                )

                widget:show()

                local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(15, height) -- Capped at default max_height=15
            end)
        end)

        -- Note: These tests call resize_dynamic_window() directly to simulate
        -- user actions that trigger buffer changes (e.g., pressing 'd' to delete
        -- files/code snippets, or agent updating todos). The resize_dynamic_window()
        -- method is called by SessionManager callbacks when content changes.
        describe("resize_dynamic_window()", function()
            it("shrinks window when content is removed", function()
                vim.bo[widget.buf_nrs.code].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2", "line3", "line4", "line5" }
                )

                widget:show()
                assert.equal(
                    6,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                -- Simulate user removing content (e.g., pressing 'd' key)
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2" }
                )

                widget:resize_dynamic_window("code")

                assert.equal(
                    3,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            it("closes window when buffer becomes empty", function()
                vim.bo[widget.buf_nrs.code].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1" }
                )

                widget:show()
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))

                -- Simulate user removing all content
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    {}
                )

                widget:resize_dynamic_window("code")

                assert.is_nil(widget.win_nrs.code)
            end)

            it("does nothing if window doesn't exist", function()
                vim.bo[widget.buf_nrs.code].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1" }
                )

                -- Don't show widget, so window doesn't exist
                assert.has_no_errors(function()
                    widget:resize_dynamic_window("code")
                end)
            end)
        end)
    end)

    describe("calculate dynamic height", function()
        --- Access private function for testing
        --- @param bufnr number
        --- @param max_height number
        --- @return integer
        local function calculate_dynamic_height(bufnr, max_height)
            ---@diagnostic disable-next-line: invisible
            return ChatWidget._calculate_dynamic_height(bufnr, max_height)
        end

        --- @param line_count number
        --- @return number bufnr
        local function create_buffer_with_lines(line_count)
            local bufnr = vim.api.nvim_create_buf(false, true)
            if line_count > 0 then
                local lines = {}
                for i = 1, line_count do
                    lines[i] = "line" .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            end
            return bufnr
        end

        local test_bufnr

        after_each(function()
            if test_bufnr and vim.api.nvim_buf_is_valid(test_bufnr) then
                vim.api.nvim_buf_delete(test_bufnr, { force = true })
            end
        end)

        -- Equivalence classes for: math.min(line_count + 1, max_height)
        -- 1. Below max: line_count + 1 < max_height -> returns line_count + 1
        -- 2. At boundary: line_count + 1 == max_height -> returns max_height
        -- 3. Above max: line_count + 1 > max_height -> returns max_height

        it("returns line_count + 1 when below max_height", function()
            test_bufnr = create_buffer_with_lines(3)
            -- 3 lines + 1 = 4, which is < 15
            assert.equal(4, calculate_dynamic_height(test_bufnr, 15))
        end)

        it(
            "returns max_height at boundary (line_count + 1 == max_height)",
            function()
                test_bufnr = create_buffer_with_lines(9)
                -- 9 lines + 1 = 10, which equals max_height
                assert.equal(10, calculate_dynamic_height(test_bufnr, 10))
            end
        )

        it("returns max_height when line_count + 1 exceeds it", function()
            test_bufnr = create_buffer_with_lines(20)
            -- 20 lines + 1 = 21, capped at 15
            assert.equal(15, calculate_dynamic_height(test_bufnr, 15))
        end)

        it("treats empty buffer as 1 line (Neovim default)", function()
            test_bufnr = vim.api.nvim_create_buf(false, true)
            -- Empty buffer has 1 line by default, so 1 + 1 = 2
            assert.equal(2, calculate_dynamic_height(test_bufnr, 15))
        end)
    end)
end)
