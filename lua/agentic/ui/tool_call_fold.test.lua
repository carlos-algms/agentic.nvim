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
    end)
end)
