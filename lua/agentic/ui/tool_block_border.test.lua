local assert = require("tests.helpers.assert")
local ToolBlockBorder = require("agentic.ui.tool_block_border")

describe("agentic.ui.ToolBlockBorder", function()
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].swapfile = false
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "before",
            "header",
            "",
            "body",
            "",
            "",
            "between",
            "header two",
            "body two",
            "",
        })
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param start_row integer
    --- @param end_row integer
    local function add_block(start_row, end_row)
        vim.api.nvim_buf_set_extmark(
            bufnr,
            ToolBlockBorder.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                end_row = end_row,
                right_gravity = false,
            }
        )
    end

    it(
        "returns corner and body glyphs from the anchored block range",
        function()
            add_block(1, 5)

            assert.equal("╭", ToolBlockBorder.glyph_for_line(bufnr, 1, 0))
            assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 2, 0))
            assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 3, 0))
            assert.equal("╰", ToolBlockBorder.glyph_for_line(bufnr, 5, 0))
        end
    )

    it("uses body glyphs for wrapped continuations", function()
        add_block(1, 5)

        assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 1, 1))
        assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 3, 2))
        assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 5, 1))
    end)

    it("uses a body glyph for folded body screen lines", function()
        add_block(1, 5)

        assert.equal("│", ToolBlockBorder.glyph_for_line(bufnr, 2, 0))
    end)

    it("does not bleed borders into lines outside or between blocks", function()
        add_block(1, 5)
        add_block(7, 9)

        assert.equal(" ", ToolBlockBorder.glyph_for_line(bufnr, 0, 0))
        assert.equal(" ", ToolBlockBorder.glyph_for_line(bufnr, 6, 0))
        assert.equal("╭", ToolBlockBorder.glyph_for_line(bufnr, 7, 0))
        assert.equal("╰", ToolBlockBorder.glyph_for_line(bufnr, 9, 0))
    end)
end)
