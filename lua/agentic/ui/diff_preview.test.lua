local assert = require("tests.helpers.assert")
local DiffPreview = require("agentic.ui.diff_preview")

describe("diff_preview", function()
    describe("clear_diff", function()
        it("clears the diff without any error", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            assert.has_no_errors(function()
                DiffPreview.clear_diff(bufnr)
            end)

            vim.api.nvim_buf_delete(bufnr, { force = true })
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

                if vim.api.nvim_buf_is_valid(new_bufnr) then
                    vim.api.nvim_buf_delete(new_bufnr, { force = true })
                end
                if vim.api.nvim_buf_is_valid(init_bufnr) then
                    vim.api.nvim_buf_delete(init_bufnr, { force = true })
                end
            end
        )

        describe("set and revert modifiable buffer option", function()
            it("restores modifiable state after clearing diff", function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                vim.bo[bufnr].modifiable = true

                -- Simulate what show_diff does: save state and set read-only
                vim.b[bufnr]._agentic_prev_modifiable = true
                vim.bo[bufnr].modifiable = false

                assert.is_false(vim.bo[bufnr].modifiable)

                DiffPreview.clear_diff(bufnr)

                assert.is_true(vim.bo[bufnr].modifiable)
                assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)

            it(
                "preserves non-modifiable state if buffer was already read-only",
                function()
                    local bufnr = vim.api.nvim_create_buf(false, true)
                    vim.bo[bufnr].modifiable = false

                    -- Simulate show_diff on already non-modifiable buffer
                    vim.b[bufnr]._agentic_prev_modifiable = false
                    vim.bo[bufnr].modifiable = false

                    DiffPreview.clear_diff(bufnr)

                    assert.is_false(vim.bo[bufnr].modifiable)
                    assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            )
        end)
    end)
end)
