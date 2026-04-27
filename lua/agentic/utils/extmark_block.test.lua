local assert = require("tests.helpers.assert")

--- @diagnostic disable: invisible

describe("extmark_block", function()
    local ExtmarkBlock = require("agentic.utils.extmark_block")

    local hl = "%#AgenticCodeBlockFence#"
    local reset = "%*"
    local pipe = hl .. "│ " .. reset
    local corner_top = hl .. "╭─" .. reset
    local corner_bottom = hl .. "╰─" .. reset
    local blank = "  "

    local function glyph(ranges, lnum, virtnum)
        return ExtmarkBlock.glyph(ranges, lnum, virtnum or 0)
    end

    after_each(function()
        ExtmarkBlock._block_cache = {}
    end)

    describe("glyph", function()
        describe("outside any block", function()
            it("returns blank for empty ranges", function()
                assert.equal(blank, glyph({}, 1))
            end)

            it("returns blank for line before block", function()
                local ranges = {
                    { start_row = 10, end_row = 20 },
                }
                assert.equal(blank, glyph(ranges, 5))
            end)

            it("returns blank for line after block", function()
                local ranges = {
                    { start_row = 10, end_row = 20 },
                }
                assert.equal(blank, glyph(ranges, 25))
            end)

            it("returns blank between blocks", function()
                local ranges = {
                    { start_row = 5, end_row = 10 },
                    { start_row = 20, end_row = 25 },
                }
                assert.equal(blank, glyph(ranges, 15))
            end)
        end)

        describe("block glyphs", function()
            local ranges = {
                { start_row = 10, end_row = 15 },
            }

            it("returns corner_top on start row", function()
                assert.equal(corner_top, glyph(ranges, 10))
            end)

            it("returns pipe on start row continuation", function()
                assert.equal(pipe, glyph(ranges, 10, 1))
            end)

            it("returns pipe on body row", function()
                assert.equal(pipe, glyph(ranges, 12))
            end)

            it("returns corner_bottom on end row", function()
                assert.equal(corner_bottom, glyph(ranges, 15))
            end)

            it("returns pipe on end row continuation", function()
                assert.equal(pipe, glyph(ranges, 15, 1))
            end)

            it("returns pipe on soft-wrapped continuation", function()
                assert.equal(pipe, glyph(ranges, 12, 1))
                assert.equal(pipe, glyph(ranges, 12, 2))
            end)

            it("returns blank for virt_lines (virtnum < 0)", function()
                assert.equal(blank, glyph(ranges, 12, -1))
                assert.equal(blank, glyph(ranges, 10, -1))
                assert.equal(blank, glyph(ranges, 15, -1))
            end)
        end)

        describe("multiple blocks", function()
            local ranges = {
                { start_row = 5, end_row = 10 },
                { start_row = 20, end_row = 25 },
            }

            it("finds first block", function()
                assert.equal(pipe, glyph(ranges, 7))
            end)

            it("finds second block", function()
                assert.equal(corner_top, glyph(ranges, 20))
            end)

            it("returns blank between blocks", function()
                assert.equal(blank, glyph(ranges, 15))
            end)
        end)

        describe("single-line block", function()
            it("returns corner_top (start == end, virtnum 0)", function()
                local ranges = {
                    { start_row = 5, end_row = 5 },
                }
                assert.equal(corner_top, glyph(ranges, 5))
            end)
        end)
    end)

    describe("update_cache", function()
        it("populates ranges from extmarks", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                buf,
                0,
                -1,
                false,
                { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }
            )
            local ns = vim.api.nvim_create_namespace("test_update_cache")
            vim.api.nvim_buf_set_extmark(buf, ns, 5, 0, { end_row = 8 })
            vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 2 })

            ExtmarkBlock.update_cache(buf, ns)
            local cache = ExtmarkBlock._block_cache[buf]

            assert.equal(2, #cache)
            assert.equal(0, cache[1].start_row)
            assert.equal(2, cache[1].end_row)
            assert.equal(5, cache[2].start_row)
            assert.equal(8, cache[2].end_row)

            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)

    describe("clear_cache", function()
        it("removes cache for buffer", function()
            local bufnr = vim.api.nvim_get_current_buf()
            ExtmarkBlock._block_cache[bufnr] = {
                { start_row = 0, end_row = 5 },
            }
            ExtmarkBlock.clear_cache(bufnr)
            assert.is_nil(ExtmarkBlock._block_cache[bufnr])
        end)
    end)
end)
