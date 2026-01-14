local assert = require("tests.helpers.assert")
local DiffPreview = require("agentic.ui.diff_preview")

describe("diff_preview", function()
    describe("clear_diff", function()
        it("clears the diff without any error", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            assert.has_no_errors(function()
                DiffPreview.clear_diff(bufnr)
            end)
        end)

        it(
            "switches to alternate buffer when clearing unsaved named buffer",
            function()
                vim.cmd("edit tests/init.lua")
                local init_bufnr = vim.api.nvim_get_current_buf()

                vim.cmd("enew")
                local new_bufnr = vim.api.nvim_get_current_buf()

                local current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, new_bufnr)

                vim.cmd("file tests/my_new_test.lua")

                DiffPreview.clear_diff(new_bufnr, true)

                current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, init_bufnr)
                vim.cmd("bd") -- Close the current buffer to clean up
            end
        )
    end)
end)
