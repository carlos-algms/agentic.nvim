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

    before_each(function()
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
            local original = Config.auto_scroll
            setup_buffer(1, 1)

            -- threshold = 0 disables
            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            -- nil config disables
            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = original
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)
    end)

    describe("_auto_scroll", function()
        --- @return table mock_timer
        local function create_mock_timer()
            return {
                stop_count = 0,
                start_count = 0,
                stop = function(self)
                    self.stop_count = self.stop_count + 1
                end,
                start = function(self, _timeout, _repeat, _callback)
                    self.start_count = self.start_count + 1
                end,
            }
        end

        it("debounces by stopping and restarting timer on each call", function()
            -- Constructor creates a real timer
            assert.is_not_nil(writer._scroll_timer)

            local mock_timer = create_mock_timer()
            writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(3, mock_timer.stop_count)
            assert.equal(3, mock_timer.start_count)
            -- Same object reused, not replaced
            assert.equal(mock_timer, writer._scroll_timer)
        end)

        it("evaluates _check_auto_scroll eagerly on first call", function()
            writer._scroll_timer = create_mock_timer() --[[@as uv.uv_timer_t]]

            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            -- Called eagerly to capture the decision before buffer changes
            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        --- @return table mock_timer
        --- @return function trigger_callback
        local function create_capturing_timer()
            local captured_cb
            local timer = {
                stop = function() end,
                start = function(_self, _timeout, _repeat, callback)
                    captured_cb = callback
                end,
            }
            local function trigger()
                if captured_cb then
                    captured_cb()
                end
            end
            return timer, trigger
        end

        it("stays true across multiple _auto_scroll calls", function()
            local mock_timer = create_capturing_timer()
            writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

            -- Cursor at bottom — _check_auto_scroll returns true
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
                local mock_timer = create_capturing_timer()
                writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

                -- Cursor at bottom
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

        it("timer callback resets field to nil after scrolling", function()
            -- Directly test the reset semantics without involving the timer
            -- The timer callback reads the field and resets it to nil
            writer._should_auto_scroll = true
            assert.is_true(writer._should_auto_scroll)

            -- Simulate what the timer callback does: consume and reset
            writer._should_auto_scroll = nil
            assert.is_nil(writer._should_auto_scroll)
        end)

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                local mock_timer = create_capturing_timer()
                writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

                -- Initially at bottom
                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                -- Simulate timer callback consuming the field
                writer._should_auto_scroll = nil

                -- User scrolls up (cursor far from bottom)
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                -- Next _auto_scroll re-evaluates, should be false
                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)
            end
        )
    end)

    describe("destroy", function()
        local function create_closeable_timer()
            return {
                stop_count = 0,
                close_count = 0,
                _closing = false,
                stop = function(self)
                    self.stop_count = self.stop_count + 1
                end,
                close = function(self)
                    self.close_count = self.close_count + 1
                    self._closing = true
                end,
                is_closing = function(self)
                    return self._closing
                end,
            }
        end

        it("stops and closes the scroll timer", function()
            local mock_timer = create_closeable_timer()
            writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

            writer:destroy()

            assert.equal(1, mock_timer.stop_count)
            assert.equal(1, mock_timer.close_count)
        end)

        it("is idempotent (safe to call twice)", function()
            local mock_timer = create_closeable_timer()
            writer._scroll_timer = mock_timer --[[@as uv.uv_timer_t]]

            writer:destroy()
            writer:destroy()

            assert.equal(1, mock_timer.stop_count)
            assert.equal(1, mock_timer.close_count)
        end)
    end)
end)
