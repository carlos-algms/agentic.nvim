--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local StatusLine = require("agentic.ui.status_line")

-- attach() only sets three fields and logs — no autocmd groups until Task 4.
-- after_each closes float windows and deletes float buffers via tracked_instances,
-- then closes split windows via tracked_wins.

--- @type integer[]
local tracked_wins

--- @type agentic.ui.StatusLine[]
local tracked_instances

--- @return integer winid
local function open_scratch_win()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
        split = "right",
        win = -1,
    })
    tracked_wins[#tracked_wins + 1] = win
    return win
end

--- Track a window for cleanup.
--- @param winid integer
local function track_win(winid)
    tracked_wins[#tracked_wins + 1] = winid
end

--- @param win_nrs table<string, integer>
--- @param position string
--- @return agentic.ui.StatusLine
local function make_attached(win_nrs, position)
    local tab = vim.api.nvim_get_current_tabpage()
    local sl = StatusLine:new()
    sl:attach(tab, win_nrs, position)
    tracked_instances[#tracked_instances + 1] = sl
    return sl
end

describe("StatusLine", function()
    before_each(function()
        tracked_wins = {}
        tracked_instances = {}
    end)

    after_each(function()
        -- Close float windows and delete float buffers owned by StatusLine instances.
        for _, sl in ipairs(tracked_instances) do
            if
                sl._float_winid and vim.api.nvim_win_is_valid(sl._float_winid)
            then
                vim.api.nvim_win_close(sl._float_winid, true)
            end
            if
                sl._float_bufnr and vim.api.nvim_buf_is_valid(sl._float_bufnr)
            then
                vim.api.nvim_buf_delete(sl._float_bufnr, { force = true })
            end
        end
        tracked_instances = {}

        -- Close tracked split windows and their backing buffers.
        for _, winid in ipairs(tracked_wins) do
            if vim.api.nvim_win_is_valid(winid) then
                local buf = vim.api.nvim_win_get_buf(winid)
                vim.api.nvim_win_close(winid, true)
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end
        end
        tracked_wins = {}
    end)

    describe("_anchor_winid", function()
        it("should return input for position=right with chat+input", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid()
            assert.equal(input, result)
        end)

        it("should return input for position=left with chat+input", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()

            local sl = make_attached({ chat = chat, input = input }, "left")
            local result = sl:_anchor_winid()
            assert.equal(input, result)
        end)

        it(
            "should return code for position=bottom with chat+input+code",
            function()
                local chat = open_scratch_win()
                local input = open_scratch_win()
                local code = open_scratch_win()

                local sl = make_attached(
                    { chat = chat, input = input, code = code },
                    "bottom"
                )
                local result = sl:_anchor_winid()
                assert.equal(code, result)
            end
        )

        it("should return todos for position=bottom with all panels", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()
            local code = open_scratch_win()
            local files = open_scratch_win()
            local diagnostics = open_scratch_win()
            local todos = open_scratch_win()

            local sl = make_attached({
                chat = chat,
                input = input,
                code = code,
                files = files,
                diagnostics = diagnostics,
                todos = todos,
            }, "bottom")
            local result = sl:_anchor_winid()
            assert.equal(todos, result)
        end)

        it(
            "should return input for position=bottom with chat+input only",
            function()
                local chat = open_scratch_win()
                local input = open_scratch_win()

                local sl =
                    make_attached({ chat = chat, input = input }, "bottom")
                local result = sl:_anchor_winid()
                assert.equal(input, result)
            end
        )

        it("should return chat when win_nrs has only chat", function()
            local chat = open_scratch_win()

            local sl = make_attached({ chat = chat }, "right")
            local result = sl:_anchor_winid()
            assert.equal(chat, result)
        end)

        it("should fall through to chat when input winid is invalid", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()
            vim.api.nvim_win_close(input, true)

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid()
            assert.equal(chat, result)
        end)

        it("should return nil for empty win_nrs", function()
            local sl = make_attached({}, "right")
            local result = sl:_anchor_winid()
            assert.is_nil(result)
        end)

        it("should return nil when all winids are invalid", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()
            vim.api.nvim_win_close(chat, true)
            vim.api.nvim_win_close(input, true)

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid()
            assert.is_nil(result)
        end)

        it(
            "should fall through to diagnostics when todos is absent for position=bottom",
            function()
                local chat = open_scratch_win()
                local input = open_scratch_win()
                local diagnostics = open_scratch_win()

                local sl = make_attached(
                    { chat = chat, input = input, diagnostics = diagnostics },
                    "bottom"
                )
                local result = sl:_anchor_winid()
                assert.equal(diagnostics, result)
            end
        )
    end)

    describe("reposition", function()
        it(
            "should create a float with relative=win anchor=NW height=1 row=anchor_height-1",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local float_winid = sl._float_winid
                track_win(float_winid)

                local cfg = vim.api.nvim_win_get_config(float_winid)
                assert.equal("win", cfg.relative)
                assert.equal("NW", cfg.anchor)
                assert.equal(1, cfg.height)

                local anchor_height = vim.api.nvim_win_get_height(input)
                assert.equal(anchor_height - 1, cfg.row)
            end
        )

        it("should set float width equal to anchor width", function()
            local input = open_scratch_win()
            local sl = make_attached({ input = input }, "right")
            sl:reposition()

            assert.is_not_nil(sl._float_winid)
            --- @type integer
            local float_winid = sl._float_winid
            track_win(float_winid)

            local anchor_width = vim.api.nvim_win_get_width(input)
            local cfg = vim.api.nvim_win_get_config(float_winid)
            assert.equal(anchor_width, cfg.width)
        end)

        it(
            "should reuse the same float winid on a second reposition call",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local first_winid = sl._float_winid
                track_win(first_winid)

                sl:reposition()
                assert.equal(first_winid, sl._float_winid)
            end
        )

        it(
            "should preserve text after a second reposition on the move path",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:set_text("stable text")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local float_winid = sl._float_winid
                track_win(float_winid)

                -- Second reposition takes the move branch (same anchor, valid float).
                sl:reposition()

                assert.is_not_nil(sl._float_bufnr)
                --- @type integer
                local bufnr = sl._float_bufnr
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
                assert.equal("stable text", lines[1])
            end
        )

        it(
            "should update float config win when anchor window changes",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local float_winid = sl._float_winid
                track_win(float_winid)

                -- Change the anchor by swapping in a new input window
                local new_input = open_scratch_win()
                sl._win_nrs = { input = new_input }
                sl:reposition()

                local cfg = vim.api.nvim_win_get_config(float_winid)
                -- cfg.win is the window handle; compare as integer
                assert.equal(new_input, cfg.win)
            end
        )

        it("should close the float when _anchor_winid returns nil", function()
            local input = open_scratch_win()
            local sl = make_attached({ input = input }, "right")
            sl:reposition()

            assert.is_not_nil(sl._float_winid)
            --- @type integer
            local float_winid = sl._float_winid
            -- Don't track_win — we expect it to be closed by reposition

            -- Invalidate the anchor
            vim.api.nvim_win_close(input, true)
            sl:reposition()

            assert.is_nil(sl._float_winid)
            assert.is_false(vim.api.nvim_win_is_valid(float_winid))
        end)

        it(
            "should display text set before float creation after reposition",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:set_text("preloaded text")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local float_winid = sl._float_winid
                track_win(float_winid)

                assert.is_not_nil(sl._float_bufnr)
                --- @type integer
                local bufnr = sl._float_bufnr

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
                assert.equal("preloaded text", lines[1])
            end
        )
    end)

    describe("set_text", function()
        it(
            "should write text to float buffer line 0 and leave buffer non-modifiable",
            function()
                local input = open_scratch_win()
                local sl = make_attached({ input = input }, "right")
                sl:reposition()

                assert.is_not_nil(sl._float_winid)
                --- @type integer
                local float_winid = sl._float_winid
                track_win(float_winid)

                assert.is_not_nil(sl._float_bufnr)
                --- @type integer
                local bufnr = sl._float_bufnr

                sl:set_text("hello")

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
                assert.equal("hello", lines[1])
                assert.is_false(vim.bo[bufnr].modifiable)
            end
        )

        it("should store text even when float does not exist yet", function()
            local sl = StatusLine:new()
            sl:set_text("pending")
            assert.equal("pending", sl._text)
        end)
    end)
end)
