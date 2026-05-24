local assert = require("tests.helpers.assert")
local ToolCallBlocks = require("agentic.ui.tool_call_blocks")

describe("agentic.ui.ToolCallBlocks", function()
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].swapfile = false

        local lines = {}
        for i = 1, 300 do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param row integer
    local function add_block(row)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ToolCallBlocks.NS_TOOL_BLOCKS,
            row,
            0,
            {
                end_row = row + 4,
                right_gravity = false,
            }
        )
    end

    describe("block_range_at_row", function()
        it("returns range when row is inside a block", function()
            add_block(10)
            assert.same(
                ToolCallBlocks.block_range_at_row(bufnr, 12),
                { start_row = 10, end_row = 14 }
            )
        end)

        it("returns nil when row has no block", function()
            add_block(10)
            assert.is_nil(ToolCallBlocks.block_range_at_row(bufnr, 9))
        end)

        it("returns nil when row is negative", function()
            assert.is_nil(ToolCallBlocks.block_range_at_row(bufnr, -1))
        end)

        it("returns nil when bufnr is invalid", function()
            assert.is_nil(ToolCallBlocks.block_range_at_row(999999, 0))
        end)
    end)

    describe("navigation_target_row", function()
        before_each(function()
            for _, row in ipairs({ 5, 50, 99, 100, 101, 150, 250 }) do
                add_block(row)
            end
        end)

        it("returns nth block target when moving forward", function()
            assert.equal(
                ToolCallBlocks.navigation_target_row(bufnr, 1, 3, 100),
                250 + ToolCallBlocks.HEADER_HEIGHT
            )
        end)

        it("returns nth block target when moving backward", function()
            -- Cursor sits inside the cluster {99, 100, 101}. Backward nav
            -- skips the current block, so count=1 -> block at row 50,
            -- count=2 -> block at row 5.
            assert.equal(
                ToolCallBlocks.navigation_target_row(bufnr, -1, 2, 100),
                5 + ToolCallBlocks.HEADER_HEIGHT
            )
        end)

        it("returns nil when count is less than 1", function()
            assert.is_nil(
                ToolCallBlocks.navigation_target_row(bufnr, 1, 0, 100)
            )
        end)

        it("returns nil when count exceeds available blocks", function()
            assert.is_nil(ToolCallBlocks.navigation_target_row(bufnr, 1, 99, 0))
        end)

        it("returns nil when moving backward from row 0", function()
            assert.is_nil(ToolCallBlocks.navigation_target_row(bufnr, -1, 1, 0))
        end)

        it("returns nil when bufnr is invalid", function()
            assert.is_nil(ToolCallBlocks.navigation_target_row(999999, 1, 1, 0))
        end)
    end)
end)
