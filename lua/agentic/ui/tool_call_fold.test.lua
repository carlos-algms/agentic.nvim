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

    --- @param blocks agentic.ui.ToolCallFold.Block[]
    local function register_blocks(blocks)
        Fold.register(bufnr, function()
            return blocks
        end)
    end

    describe("foldexpr", function()
        it("returns 0 when no instance is registered", function()
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 10), 0)
        end)

        it("returns 0 when getter returns empty list", function()
            register_blocks({})
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 50), 0)
        end)

        -- Single foldable block spanning rows 0..16 (header=line 1, footer=line 17,
        -- interior=lines 2..16 in 1-indexed). Covers header/footer/interior/outside
        -- boundaries for a foldable block.
        it("folds only the interior lines of a foldable block", function()
            register_blocks({
                { start_row = 0, end_row = 16, foldable = true },
            })
            --- @type { lnum: integer, expected: integer, label: string }[]
            local cases = {
                { lnum = 1, expected = 0, label = "header" },
                { lnum = 2, expected = 1, label = "first interior" },
                { lnum = 10, expected = 1, label = "mid interior" },
                { lnum = 16, expected = 1, label = "last interior" },
                { lnum = 17, expected = 0, label = "footer" },
                { lnum = 50, expected = 0, label = "outside" },
            }
            for _, c in ipairs(cases) do
                assert.equal(Fold.foldexpr(bufnr, c.lnum), c.expected)
            end
        end)

        it("returns 0 for non-foldable block even in interior", function()
            register_blocks({
                { start_row = 0, end_row = 16, foldable = false },
            })
            assert.equal(Fold.foldexpr(bufnr, 2), 0)
            assert.equal(Fold.foldexpr(bufnr, 10), 0)
        end)

        it("returns 0 for block with empty interior", function()
            register_blocks({
                { start_row = 0, end_row = 1, foldable = true },
            })
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
            assert.equal(Fold.foldexpr(bufnr, 2), 0)
        end)

        it("handles multiple mixed blocks per lnum", function()
            register_blocks({
                { start_row = 0, end_row = 5, foldable = false },
                { start_row = 10, end_row = 30, foldable = true },
                { start_row = 35, end_row = 40, foldable = false },
            })
            --- @type { lnum: integer, expected: integer }[]
            local cases = {
                { lnum = 3, expected = 0 },
                { lnum = 8, expected = 0 },
                { lnum = 11, expected = 0 },
                { lnum = 12, expected = 1 },
                { lnum = 25, expected = 1 },
                { lnum = 30, expected = 1 },
                { lnum = 38, expected = 0 },
            }
            for _, c in ipairs(cases) do
                assert.equal(Fold.foldexpr(bufnr, c.lnum), c.expected)
            end
        end)
    end)

    describe("setup_window", function()
        local Config = require("agentic.config")
        --- @type agentic.UserConfig.Folding|nil
        local saved_folding
        --- @type integer
        local winid

        --- @return string
        local function expected_foldexpr()
            return string.format(
                "v:lua.require'agentic.ui.tool_call_fold'.foldexpr(%d, v:lnum)",
                bufnr
            )
        end

        before_each(function()
            saved_folding = Config.folding
            Config.folding = {
                tool_calls = { enabled = true, threshold = 10 },
            }
            winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 0,
                col = 0,
                width = 40,
                height = 20,
            })
        end)

        after_each(function()
            if vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
            end
            Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        end)

        it("applies fold options to the window", function()
            Fold.setup_window(winid, bufnr)

            assert.equal(vim.wo[winid].foldmethod, "expr")
            assert.equal(vim.wo[winid].foldexpr, expected_foldexpr())
            assert.equal(vim.wo[winid].foldlevel, 0)
            assert.is_true(vim.wo[winid].foldenable)
            assert.equal(
                vim.wo[winid].foldtext,
                "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"
            )
        end)

        it("does not apply options when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 10 },
            }

            Fold.setup_window(winid, bufnr)

            assert.equal(vim.wo[winid].foldmethod, "manual")
            assert.is_not.equal(vim.wo[winid].foldexpr, expected_foldexpr())
        end)

        it("does not reset foldlevel on subsequent calls", function()
            Fold.setup_window(winid, bufnr)
            assert.equal(vim.wo[winid].foldlevel, 0)

            -- Simulate a fold opened by the user. Re-applying must NOT reset
            -- foldlevel, or the fold would close on the next widget rerender.
            vim.wo[winid].foldlevel = 99
            Fold.setup_window(winid, bufnr)
            assert.equal(vim.wo[winid].foldlevel, 99)
        end)
    end)

    describe("foldtext", function()
        it("formats the hidden line count", function()
            vim.v.foldstart = 3
            vim.v.foldend = 12
            assert.equal(
                Fold.foldtext(),
                "  10 lines hidden (Fold: `zo` open | `zc` close)"
            )
        end)
    end)

    describe("register and unregister", function()
        it("unregister removes the entry", function()
            register_blocks({
                { start_row = 0, end_row = 16, foldable = true },
            })
            Fold.unregister(bufnr)
            assert.equal(Fold.foldexpr(bufnr, 5), 0)
        end)

        it("re-register replaces the previous getter", function()
            register_blocks({
                { start_row = 0, end_row = 16, foldable = true },
            })
            register_blocks({})
            assert.equal(Fold.foldexpr(bufnr, 5), 0)
        end)

        it("unregister is safe when bufnr not registered", function()
            Fold.unregister(bufnr)
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
        end)
    end)
end)
