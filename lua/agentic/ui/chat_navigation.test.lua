local assert = require("tests.helpers.assert")
local ChatNavigation = require("agentic.ui.chat_navigation")
local Config = require("agentic.config")
local ToolCallBlocks = require("agentic.ui.tool_call_blocks")

describe("agentic.ui.ChatNavigation", function()
    --- @type integer
    local bufnr
    --- @type integer|nil
    local winid

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].swapfile = false
        vim.bo[bufnr].filetype = "AgenticChat"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "# One",
            "",
            "## Two",
            "",
            "### Three",
            "",
            "#### Four",
        })
    end)

    after_each(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        winid = nil
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param row integer 0-indexed
    local function open_window_at(row)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 20,
            row = 0,
            col = 0,
        })
        vim.api.nvim_win_set_cursor(winid, { row + 1, 0 })
    end

    --- @return integer row 0-indexed cursor row
    local function cursor_row()
        assert.is_not_nil(winid)
        ---@cast winid integer
        return vim.api.nvim_win_get_cursor(winid)[1] - 1
    end

    describe("heading_target_row", function()
        --- @type { name: string, dir: integer, count: integer, cursor: integer, expected: integer|nil }[]
        local cases = {
            {
                name = "forward in-range from before buffer",
                dir = 1,
                count = 2,
                cursor = -1,
                expected = 2,
            },
            {
                name = "forward exhausts available headings (h4 filtered)",
                dir = 1,
                count = 4,
                cursor = -1,
                expected = nil,
            },
            {
                name = "forward skips current cursor row",
                dir = 1,
                count = 1,
                cursor = 0,
                expected = 2,
            },
            {
                name = "backward in-range skips current cursor row",
                dir = -1,
                count = 2,
                cursor = 4,
                expected = 0,
            },
            {
                name = "count < 1 returns nil",
                dir = 1,
                count = 0,
                cursor = -1,
                expected = nil,
            },
        }

        for _, case in ipairs(cases) do
            it(case.name, function()
                local row = ChatNavigation.heading_target_row(
                    bufnr,
                    case.dir,
                    case.count,
                    case.cursor
                )
                assert.equal(row, case.expected)
            end)
        end
    end)

    describe("next_heading / prev_heading", function()
        it("next_heading jumps cursor to next heading row", function()
            open_window_at(0)
            ChatNavigation.next_heading(bufnr, 1)
            assert.equal(cursor_row(), 2)
        end)

        it("prev_heading jumps cursor to previous heading row", function()
            open_window_at(4)
            ChatNavigation.prev_heading(bufnr, 1)
            assert.equal(cursor_row(), 2)
        end)

        it("next_heading respects count parameter", function()
            open_window_at(0)
            ChatNavigation.next_heading(bufnr, 2)
            assert.equal(cursor_row(), 4)
        end)

        it("next_heading is a no-op when no heading remains", function()
            open_window_at(4)
            ChatNavigation.next_heading(bufnr, 99)
            assert.equal(cursor_row(), 4)
        end)

        it("normalizes nil count to vim.v.count1 (default 1)", function()
            open_window_at(0)
            ChatNavigation.next_heading(bufnr)
            assert.equal(cursor_row(), 2)
        end)
    end)

    describe("next_tool_call / prev_tool_call", function()
        before_each(function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

            for _, start_row in ipairs({ 5, 20, 35 }) do
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    ToolCallBlocks.NS_TOOL_BLOCKS,
                    start_row,
                    0,
                    { end_row = start_row + 4, right_gravity = false }
                )
            end
        end)

        it(
            "next_tool_call lands on body row (start_row + HEADER_HEIGHT)",
            function()
                open_window_at(0)
                ChatNavigation.next_tool_call(bufnr, 1)
                assert.equal(cursor_row(), 5 + ToolCallBlocks.HEADER_HEIGHT)
            end
        )

        it("prev_tool_call lands on previous block body row", function()
            open_window_at(15)
            ChatNavigation.prev_tool_call(bufnr, 1)
            assert.equal(cursor_row(), 5 + ToolCallBlocks.HEADER_HEIGHT)
        end)

        it("next_tool_call is a no-op when no block remains", function()
            open_window_at(40)
            ChatNavigation.next_tool_call(bufnr, 1)
            assert.equal(cursor_row(), 40)
        end)

        it(
            "prev_tool_call from inside a block jumps to the previous block, not the current one",
            function()
                open_window_at(20 + ToolCallBlocks.HEADER_HEIGHT)
                ChatNavigation.prev_tool_call(bufnr, 1)
                assert.equal(cursor_row(), 5 + ToolCallBlocks.HEADER_HEIGHT)
            end
        )

        it(
            "next_tool_call from inside a block jumps to the next block, not the current one",
            function()
                open_window_at(5 + ToolCallBlocks.HEADER_HEIGHT)
                ChatNavigation.next_tool_call(bufnr, 1)
                assert.equal(cursor_row(), 20 + ToolCallBlocks.HEADER_HEIGHT)
            end
        )
    end)

    describe("setup_keymaps", function()
        --- @param mode string
        --- @param lhs string
        --- @return boolean
        local function has_keymap(mode, lhs)
            for _, km in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
                if km.lhs == lhs then
                    return true
                end
            end
            return false
        end

        it("registers buffer-local keymaps for all nav actions", function()
            ChatNavigation.setup_keymaps(bufnr)

            local keymaps = Config.keymaps.chat
            --- @param value agentic.UserConfig.KeymapValue
            --- @return string
            local function first_lhs(value)
                if type(value) == "string" then
                    return value
                end
                local entry = value[1]
                if type(entry) == "table" then
                    return entry[1]
                end
                return entry --[[@as string]]
            end

            assert.is_true(has_keymap("n", first_lhs(keymaps.next_heading)))
            assert.is_true(has_keymap("n", first_lhs(keymaps.prev_heading)))
            assert.is_true(has_keymap("n", first_lhs(keymaps.next_tool_call)))
            assert.is_true(has_keymap("n", first_lhs(keymaps.prev_tool_call)))
        end)
    end)
end)
