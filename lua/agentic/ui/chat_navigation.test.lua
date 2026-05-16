local assert = require("tests.helpers.assert")
local ChatNavigation = require("agentic.ui.chat_navigation")

describe("agentic.ui.ChatNavigation", function()
    local bufnr

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
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

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
end)
