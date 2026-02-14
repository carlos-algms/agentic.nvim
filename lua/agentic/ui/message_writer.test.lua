--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- Fill buffer with numbered lines and set cursor position
    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                -- 5 lines from end, within default threshold of 10
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            -- 49 lines from end, well beyond threshold
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it(
            "returns true when buffer is on a different tabpage with cursor at bottom",
            function()
                -- Create a new tab with a window showing a separate buffer
                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                -- The original bufnr+winid are on tab1 (from before_each).
                -- writer:_check_auto_scroll uses vim.fn.win_findbuf(bufnr)
                -- which searches ALL tabpages, so it finds the real window
                -- on tab1 and checks the actual cursor position. The test
                -- passes because cursor line 18 of 20 is within threshold.
                setup_buffer(20, 18)
                assert.is_true(writer:_check_auto_scroll(bufnr))

                -- Cleanup: close tab2 to return to tab1
                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")
            end
        )

        it(
            "returns false when buffer is on a different tabpage with cursor scrolled up",
            function()
                -- Put cursor far from bottom while on tab1
                setup_buffer(50, 1)
                assert.is_false(writer:_check_auto_scroll(bufnr))

                -- Switch to tab2 — win_findbuf still finds the real window
                -- on tab1, so cursor position is checked correctly and the
                -- user's scroll-up intent is respected.
                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()
                assert.is_false(writer:_check_auto_scroll(bufnr))

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")
            end
        )
    end)

    describe("_auto_scroll", function()
        it("coalesces multiple calls into a single scheduled scroll", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            -- Subsequent calls are no-ops while scheduled
            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            -- _check_auto_scroll is not called again (sticky true)
            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)

        it("evaluates _check_auto_scroll eagerly on first call", function()
            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it("stays true across multiple _auto_scroll calls", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._should_auto_scroll)

            -- Second call should skip re-evaluation, field stays true
            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            assert.is_true(writer._should_auto_scroll)
            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)

        it(
            "remains true after large buffer growth (simulates tool call block)",
            function()
                setup_buffer(20, 20)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                -- Simulate large buffer growth (30 lines added)
                local lines = {}
                for i = 1, 30 do
                    lines[i] = "tool output " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

                -- Cursor is still at line 20, buffer is now 50 lines
                -- distance_from_bottom = 30, exceeds threshold
                -- But sticky field should prevent re-evaluation
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)
            end
        )

        it("scheduled callback resets field to nil after scrolling", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)

            setup_buffer(20, 20)
            writer:_auto_scroll(bufnr)
            assert.is_nil(writer._should_auto_scroll)

            schedule_stub:revert()
        end)

        it("scheduled callback moves cursor to the last line", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)

            setup_buffer(50, 1)
            -- Force auto-scroll on despite cursor being far from bottom
            writer._should_auto_scroll = true
            writer:_auto_scroll(bufnr)

            local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
            assert.equal(50, cursor_line)

            schedule_stub:revert()
        end)

        it(
            "scheduled callback scrolls when user is on a different tabpage",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                -- Cursor at bottom, auto-scroll should engage
                setup_buffer(20, 20)

                -- Add 30 lines to simulate streaming content
                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                -- Switch to a different tab (simulating user working elsewhere)
                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                -- Force the scroll decision and trigger the callback
                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                -- Cursor on the chat window (tab1) should be at the last line
                local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
                assert.equal(50, cursor_line)

                -- Cleanup
                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

                schedule_stub:revert()
            end
        )

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                -- Run the first schedule synchronously to reset the field
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_nil(writer._should_auto_scroll)
                assert.is_false(writer._scroll_scheduled)

                schedule_stub:revert()

                -- Defer the second schedule to inspect the field before reset
                schedule_stub = spy.stub(vim, "schedule")

                -- User scrolls up (cursor far from bottom)
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                -- Next _auto_scroll re-evaluates, should be false
                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            -- Prevent vim.schedule from firing so we can inspect
            -- _should_auto_scroll before the callback resets it.
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write_message captures scroll decision before buffer grows",
            function()
                -- Cursor at bottom of a small buffer
                setup_buffer(10, 10)

                -- Write a large message (50 lines) via the real public method
                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                --- @type agentic.acp.SessionUpdateMessage
                local update = {
                    sessionUpdate = "agent_message_chunk",
                    content = {
                        type = "text",
                        text = table.concat(long_text, "\n"),
                    },
                }
                writer:write_message(update)

                -- Decision was captured BEFORE the 50 lines were written
                -- Cursor was at line 10 of 10 (distance=0, within threshold)
                assert.is_true(writer._should_auto_scroll)
            end
        )

        it(
            "write_tool_call_block captures scroll decision before buffer grows",
            function()
                -- Cursor at bottom of a small buffer
                setup_buffer(10, 10)

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = {
                        "file1.lua",
                        "file2.lua",
                        "file3.lua",
                        "file4.lua",
                        "file5.lua",
                        "file6.lua",
                        "file7.lua",
                        "file8.lua",
                        "file9.lua",
                        "file10.lua",
                        "file11.lua",
                        "file12.lua",
                        "file13.lua",
                        "file14.lua",
                        "file15.lua",
                    },
                }
                writer:write_tool_call_block(block)

                -- Decision was captured BEFORE the block lines were written
                assert.is_true(writer._should_auto_scroll)

                -- Buffer grew significantly (header + 15 body + footer + spacing)
                local total = vim.api.nvim_buf_line_count(bufnr)
                assert.is_true(total > 20)
            end
        )

        it("write_message does not scroll when user has scrolled up", function()
            -- 50-line buffer, cursor at line 1 (scrolled up)
            setup_buffer(50, 1)

            --- @type agentic.acp.SessionUpdateMessage
            local update = {
                sessionUpdate = "agent_message_chunk",
                content = {
                    type = "text",
                    text = "new content\nmore content",
                },
            }
            writer:write_message(update)

            -- Cursor was far from bottom, decision captured as false
            assert.is_false(writer._should_auto_scroll)
        end)
    end)
end)
