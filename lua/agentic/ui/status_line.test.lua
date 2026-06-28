local assert = require("tests.helpers.assert")
local StatusLine = require("agentic.ui.status_line")

-- attach() only sets three fields and logs — no autocmd groups until Task 4.
-- No destroy() call needed in after_each; window cleanup via tracked_wins list.

--- @type integer[]
local tracked_wins

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

--- @param win_nrs table<string, integer>
--- @param position string
--- @return agentic.ui.StatusLine
local function make_attached(win_nrs, position)
    local tab = vim.api.nvim_get_current_tabpage()
    local sl = StatusLine:new()
    sl:attach(tab, win_nrs, position)
    return sl
end

describe("StatusLine", function()
    before_each(function()
        tracked_wins = {}
    end)

    after_each(function()
        for _, winid in ipairs(tracked_wins) do
            if vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
            end
        end
        tracked_wins = {}
    end)

    describe("_anchor_winid", function()
        it("should return input for position=right with chat+input", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

            assert.equal(input, result)
        end)

        it("should return input for position=left with chat+input", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()

            local sl = make_attached({ chat = chat, input = input }, "left")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

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
                local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

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
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

            assert.equal(todos, result)
        end)

        it(
            "should return input for position=bottom with chat+input only",
            function()
                local chat = open_scratch_win()
                local input = open_scratch_win()

                local sl =
                    make_attached({ chat = chat, input = input }, "bottom")
                local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

                assert.equal(input, result)
            end
        )

        it("should return chat when win_nrs has only chat", function()
            local chat = open_scratch_win()

            local sl = make_attached({ chat = chat }, "right")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

            assert.equal(chat, result)
        end)

        it("should fall through to chat when input winid is invalid", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()
            vim.api.nvim_win_close(input, true)

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

            assert.equal(chat, result)
        end)

        it("should return nil for empty win_nrs", function()
            local sl = make_attached({}, "right")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

            assert.is_nil(result)
        end)

        it("should return nil when all winids are invalid", function()
            local chat = open_scratch_win()
            local input = open_scratch_win()
            vim.api.nvim_win_close(chat, true)
            vim.api.nvim_win_close(input, true)

            local sl = make_attached({ chat = chat, input = input }, "right")
            local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

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
                local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

                assert.equal(diagnostics, result)
            end
        )
    end)
end)
