local assert = require("tests.helpers.assert")
local Fold = require("agentic.ui.tool_call_fold")

describe("agentic.ui.ToolCallFold", function()
    --- @type number
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        Fold.unregister(bufnr)
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("foldexpr", function()
        it("returns 0 when no instance is registered", function()
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 10), 0)
        end)

        it("returns 1 for lnum inside a foldable block interior", function()
            Fold.register(bufnr, function()
                return {
                    {
                        start_row = 0,
                        end_row = 16,
                        foldable = true,
                    },
                }
            end)
            -- Interior is start_row+2..end_row in 1-indexed: lines 2..16
            assert.equal(Fold.foldexpr(bufnr, 2), 1)
            assert.equal(Fold.foldexpr(bufnr, 10), 1)
            assert.equal(Fold.foldexpr(bufnr, 16), 1)
        end)

        it("returns 0 when getter returns empty list", function()
            Fold.register(bufnr, function()
                return {}
            end)
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 50), 0)
        end)

        it("returns 0 for lnum on header line", function()
            Fold.register(bufnr, function()
                return {
                    {
                        start_row = 0,
                        end_row = 16,
                        foldable = true,
                    },
                }
            end)
            -- Header is start_row+1 in 1-indexed: line 1
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
        end)

        it("returns 0 for lnum on footer line", function()
            Fold.register(bufnr, function()
                return {
                    {
                        start_row = 0,
                        end_row = 16,
                        foldable = true,
                    },
                }
            end)
            -- Footer is end_row+1 in 1-indexed: line 17
            assert.equal(Fold.foldexpr(bufnr, 17), 0)
        end)

        it("returns 0 for lnum outside the block", function()
            Fold.register(bufnr, function()
                return {
                    {
                        start_row = 5,
                        end_row = 20,
                        foldable = true,
                    },
                }
            end)
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 5), 0)
            assert.equal(Fold.foldexpr(bufnr, 22), 0)
        end)

        it("returns 0 for non-foldable block even in interior", function()
            Fold.register(bufnr, function()
                return {
                    {
                        start_row = 0,
                        end_row = 16,
                        foldable = false,
                    },
                }
            end)
            assert.equal(Fold.foldexpr(bufnr, 2), 0)
            assert.equal(Fold.foldexpr(bufnr, 10), 0)
        end)

        it("handles multiple mixed blocks correctly per lnum", function()
            Fold.register(bufnr, function()
                return {
                    { start_row = 0, end_row = 5, foldable = false },
                    { start_row = 10, end_row = 30, foldable = true },
                    { start_row = 35, end_row = 40, foldable = false },
                }
            end)
            assert.equal(Fold.foldexpr(bufnr, 3), 0)
            assert.equal(Fold.foldexpr(bufnr, 8), 0)
            assert.equal(Fold.foldexpr(bufnr, 12), 1)
            assert.equal(Fold.foldexpr(bufnr, 25), 1)
            assert.equal(Fold.foldexpr(bufnr, 30), 1)
            assert.equal(Fold.foldexpr(bufnr, 11), 0)
            assert.equal(Fold.foldexpr(bufnr, 38), 0)
        end)

        it(
            "returns 0 for block with empty interior (end_row <= start_row+1)",
            function()
                Fold.register(bufnr, function()
                    return {
                        { start_row = 0, end_row = 1, foldable = true },
                    }
                end)
                assert.equal(Fold.foldexpr(bufnr, 1), 0)
                assert.equal(Fold.foldexpr(bufnr, 2), 0)
            end
        )
    end)
end)
