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

    describe("setup_window", function()
        local Config = require("agentic.config")
        --- @type agentic.UserConfig.Folding|nil
        local saved_folding

        before_each(function()
            saved_folding = Config.folding
            Config.folding = {
                tool_calls = { enabled = true, threshold = 10 },
            }
        end)

        after_each(function()
            Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
        end)

        it(
            "applies foldmethod, foldexpr, foldlevel, foldenable, foldtext to the window",
            function()
                local winid = vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    row = 0,
                    col = 0,
                    width = 40,
                    height = 20,
                })

                Fold.setup_window(winid, bufnr)

                assert.equal(vim.wo[winid].foldmethod, "expr")
                assert.equal(
                    vim.wo[winid].foldexpr,
                    string.format(
                        "v:lua.require'agentic.ui.tool_call_fold'.foldexpr(%d, v:lnum)",
                        bufnr
                    )
                )
                assert.equal(vim.wo[winid].foldlevel, 0)
                assert.is_true(vim.wo[winid].foldenable)
                assert.equal(
                    vim.wo[winid].foldtext,
                    "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"
                )

                vim.api.nvim_win_close(winid, true)
            end
        )

        it("does not apply options when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 10 },
            }

            local winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 0,
                col = 0,
                width = 40,
                height = 20,
            })

            Fold.setup_window(winid, bufnr)

            -- Default Neovim values are preserved; our foldmethod/foldexpr are not applied.
            assert.equal(vim.wo[winid].foldmethod, "manual")
            assert.is_not.equal(
                vim.wo[winid].foldexpr,
                string.format(
                    "v:lua.require'agentic.ui.tool_call_fold'.foldexpr(%d, v:lnum)",
                    bufnr
                )
            )

            vim.api.nvim_win_close(winid, true)
        end)

        it(
            "does not reset foldlevel on subsequent calls to the same window",
            function()
                local winid = vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    row = 0,
                    col = 0,
                    width = 40,
                    height = 20,
                })

                Fold.setup_window(winid, bufnr)
                assert.equal(vim.wo[winid].foldlevel, 0)

                -- Simulate a fold being opened by the user (raise foldlevel).
                vim.wo[winid].foldlevel = 99

                -- Re-applying must NOT reset foldlevel, or the user's opened fold
                -- would close again on the next chat widget rerender.
                Fold.setup_window(winid, bufnr)
                assert.equal(vim.wo[winid].foldlevel, 99)

                vim.api.nvim_win_close(winid, true)
            end
        )
    end)

    describe("foldtext", function()
        it("formats the hidden line count", function()
            -- Simulate v:foldstart and v:foldend
            vim.v.foldstart = 3
            vim.v.foldend = 12
            local text = Fold.foldtext()
            assert.equal(text, "  10 lines hidden (zo open | zc close)")
        end)
    end)

    describe("register and unregister", function()
        it("register adds an entry foldexpr can find", function()
            Fold.register(bufnr, function()
                return {
                    { start_row = 0, end_row = 16, foldable = true },
                }
            end)
            assert.equal(Fold.foldexpr(bufnr, 5), 1)
        end)

        it("unregister removes the entry", function()
            Fold.register(bufnr, function()
                return {
                    { start_row = 0, end_row = 16, foldable = true },
                }
            end)
            Fold.unregister(bufnr)
            assert.equal(Fold.foldexpr(bufnr, 5), 0)
        end)

        it("re-register replaces the previous getter", function()
            Fold.register(bufnr, function()
                return {
                    { start_row = 0, end_row = 16, foldable = true },
                }
            end)
            Fold.register(bufnr, function()
                return {}
            end)
            assert.equal(Fold.foldexpr(bufnr, 5), 0)
        end)

        it("unregister is safe when bufnr not registered", function()
            Fold.unregister(bufnr) -- no error
            assert.equal(Fold.foldexpr(bufnr, 1), 0)
        end)
    end)
end)
