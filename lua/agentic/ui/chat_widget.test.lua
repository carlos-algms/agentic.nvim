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
            -- Create a new tabpage for each test
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            -- Create widget instance
            local on_submit_spy = spy.new(function() end)
            widget =
                ChatWidget:new(tab_page_id, on_submit_spy --[[@as function]])
        end)

        after_each(function()
            -- Clean up widget
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end

            -- Close the tabpage
            vim.cmd("tabclose")
        end)

        it("creates widget with valid buffer IDs", function()
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
            assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
        end)

        it("is_open returns falsy when widget is not shown", function()
            local is_open = widget:is_open()
            assert.is_falsy(is_open)
        end)

        it("show() creates chat and input windows", function()
            widget:show()

            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.input))

            -- Other windows should not be created when buffers are empty
            assert.is_nil(widget.win_nrs.code)
            assert.is_nil(widget.win_nrs.files)
            assert.is_nil(widget.win_nrs.todos)
        end)

        it("hide() closes all open windows", function()
            widget:show()

            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input

            assert.is_true(vim.api.nvim_win_is_valid(chat_win))
            assert.is_true(vim.api.nvim_win_is_valid(input_win))

            widget:hide()

            assert.is_false(vim.api.nvim_win_is_valid(chat_win))
            assert.is_false(vim.api.nvim_win_is_valid(input_win))

            assert.is_nil(widget.win_nrs.chat)
            assert.is_nil(widget.win_nrs.input)
        end)

        it("is_open returns falsy after hide()", function()
            widget:show()
            assert.is_true(widget:is_open())

            widget:hide()
            local is_open = widget:is_open()
            assert.is_falsy(is_open)
        end)

        it("hide() preserves buffer IDs", function()
            widget:show()

            local chat_buf = widget.buf_nrs.chat
            local input_buf = widget.buf_nrs.input

            widget:hide()

            assert.equal(chat_buf, widget.buf_nrs.chat)
            assert.equal(input_buf, widget.buf_nrs.input)
            assert.is_true(vim.api.nvim_buf_is_valid(chat_buf))
            assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
        end)

        it("show() can be called multiple times without error", function()
            widget:show()
            local first_chat_win = widget.win_nrs.chat

            widget:show()
            local second_chat_win = widget.win_nrs.chat

            assert.equal(first_chat_win, second_chat_win)
            assert.is_true(vim.api.nvim_win_is_valid(second_chat_win))
        end)

        it("hide() can be called multiple times without error", function()
            widget:show()
            widget:hide()

            assert.has_no_errors(function()
                widget:hide()
            end)
        end)

        it("show() after hide() recreates windows", function()
            widget:show()
            local first_chat_win = widget.win_nrs.chat

            widget:hide()

            widget:show()
            local second_chat_win = widget.win_nrs.chat

            -- Windows should be different after hide/show cycle
            assert.are_not.equal(first_chat_win, second_chat_win)
            assert.is_false(vim.api.nvim_win_is_valid(first_chat_win))
            assert.is_true(vim.api.nvim_win_is_valid(second_chat_win))
        end)

        it("windows are created in correct tabpage", function()
            widget:show()

            local chat_win = widget.win_nrs.chat
            local input_win = widget.win_nrs.input

            local chat_tab = vim.api.nvim_win_get_tabpage(chat_win)
            local input_tab = vim.api.nvim_win_get_tabpage(input_win)

            assert.equal(tab_page_id, chat_tab)
            assert.equal(tab_page_id, input_tab)
        end)

        it("hide() stops insert mode", function()
            widget:show()

            -- Focus input window and enter insert mode
            vim.api.nvim_set_current_win(widget.win_nrs.input)
            vim.cmd("startinsert")

            widget:hide()

            -- Should exit insert mode
            assert.are_not.equal("i", vim.fn.mode())
        end)

        it(
            "show() creates files window when files buffer has content",
            function()
                -- Add content to files buffer
                vim.bo[widget.buf_nrs.files].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.files,
                    0,
                    -1,
                    false,
                    { "file1.lua", "file2.lua" }
                )

                widget:show()

                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.files))

                -- Verify window is in correct tabpage
                local files_tab =
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.files)
                assert.equal(tab_page_id, files_tab)
            end
        )

        it("show() creates code window when code buffer has content", function()
            -- Add content to code buffer
            vim.bo[widget.buf_nrs.code].modifiable = true
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.code,
                0,
                -1,
                false,
                { "local foo = 'bar'", "print(foo)" }
            )

            widget:show()

            assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))

            -- Verify window is in correct tabpage
            local code_tab = vim.api.nvim_win_get_tabpage(widget.win_nrs.code)
            assert.equal(tab_page_id, code_tab)
        end)

        it(
            "show() creates both files and code windows when both buffers have content",
            function()
                -- Add content to files buffer
                vim.bo[widget.buf_nrs.files].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.files,
                    0,
                    -1,
                    false,
                    { "file1.lua", "file2.lua" }
                )

                -- Add content to code buffer
                vim.bo[widget.buf_nrs.code].modifiable = true
                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "local foo = 'bar'", "print(foo)" }
                )

                widget:show()

                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.files))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.code))
            end
        )

        it("hide() closes files and code windows when they exist", function()
            -- Add content to files and code buffers
            vim.bo[widget.buf_nrs.files].modifiable = true
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.files,
                0,
                -1,
                false,
                { "file1.lua" }
            )
            vim.bo[widget.buf_nrs.code].modifiable = true
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.code,
                0,
                -1,
                false,
                { "local foo = 'bar'" }
            )

            widget:show()

            local files_win = widget.win_nrs.files
            local code_win = widget.win_nrs.code

            assert.is_true(vim.api.nvim_win_is_valid(files_win))
            assert.is_true(vim.api.nvim_win_is_valid(code_win))

            widget:hide()

            assert.is_false(vim.api.nvim_win_is_valid(files_win))
            assert.is_false(vim.api.nvim_win_is_valid(code_win))
            assert.is_nil(widget.win_nrs.files)
            assert.is_nil(widget.win_nrs.code)
        end)
    end)
end)
