local assert = require("tests.helpers.assert")
local Fold = require("agentic.ui.tool_call_fold")
local Config = require("agentic.config")

describe("agentic.ui.ToolCallFold", function()
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.UserConfig.Folding|nil
    local saved_folding

    before_each(function()
        saved_folding = Config.folding
        Config.folding = {
            tool_calls = { enabled = true, threshold = 5 },
        }
        bufnr = vim.api.nvim_create_buf(false, true)
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
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        Config.folding = saved_folding --- @diagnostic disable-line: assign-type-mismatch
    end)

    describe("threshold", function()
        it("returns the configured threshold", function()
            assert.equal(Fold.threshold(), 5)
        end)

        it("returns nil when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 5 },
            }
            assert.is_nil(Fold.threshold())
        end)

        it("clamps negative thresholds to 0", function()
            Config.folding = {
                tool_calls = { enabled = true, threshold = -3 },
            }
            assert.equal(Fold.threshold(), 0)
        end)
    end)

    describe("should_fold", function()
        it("folds when interior > threshold", function()
            assert.is_true(Fold.should_fold(6, false))
        end)

        it("does not fold when interior == threshold", function()
            assert.is_false(Fold.should_fold(5, false))
        end)

        it("never folds diff blocks regardless of size", function()
            assert.is_false(Fold.should_fold(100, true))
        end)

        it("returns false when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 5 },
            }
            assert.is_false(Fold.should_fold(100, false))
        end)
    end)

    describe("setup_window", function()
        it("applies manual fold options to the window", function()
            Fold.setup_window(winid, bufnr)

            assert.equal(vim.wo[winid].foldmethod, "manual")
            assert.equal(vim.wo[winid].foldlevel, 0)
            assert.is_true(vim.wo[winid].foldenable)
            assert.equal(
                vim.wo[winid].foldtext,
                "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"
            )
        end)

        it("does not apply options when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 5 },
            }
            Fold.setup_window(winid, bufnr)
            -- foldmethod default is "manual" so we cannot use that as
            -- the marker; assert that foldtext was NOT set instead.
            assert.is_not.equal(
                vim.wo[winid].foldtext,
                "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"
            )
        end)

        it("restores foldlevel and foldenable when drifted", function()
            Fold.setup_window(winid, bufnr)
            assert.equal(vim.wo[winid].foldlevel, 0)

            vim.wo[winid].foldlevel = 99
            vim.wo[winid].foldenable = false
            Fold.setup_window(winid, bufnr)
            assert.equal(vim.wo[winid].foldlevel, 0)
            assert.is_true(vim.wo[winid].foldenable)
        end)

        it("preserves manually-opened folds across repeated calls", function()
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                vim.fn["repeat"]({ "L" }, 30)
            )
            Fold.setup_window(winid, bufnr)
            vim.api.nvim_win_call(winid, function()
                vim.cmd("silent! 5,15fold")
                vim.cmd("normal! 10G")
                vim.cmd("normal! zo")
                assert.equal(vim.fn.foldclosed(10), -1)
            end)

            Fold.setup_window(winid, bufnr)
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(10), -1)
            end)
        end)

        it("preserves fold ranges across window close + reopen", function()
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                vim.fn["repeat"]({ "L" }, 60)
            )
            Fold.setup_window(winid, bufnr)
            Fold.close_range(bufnr, 5, 15)
            Fold.close_range(bufnr, 25, 35)
            Fold.close_range(bufnr, 45, 55)

            vim.api.nvim_win_close(winid, true)
            winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 0,
                col = 0,
                width = 40,
                height = 20,
            })
            Fold.setup_window(winid, bufnr)

            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(10), 5)
                assert.equal(vim.fn.foldclosed(30), 25)
                assert.equal(vim.fn.foldclosed(50), 45)
                assert.equal(vim.fn.foldclosedend(10), 15)
                assert.equal(vim.fn.foldclosedend(30), 35)
                assert.equal(vim.fn.foldclosedend(50), 55)
            end)
        end)

        it(
            "preserves folds when user has non-manual foldmethod global",
            function()
                local saved_global = vim.go.foldmethod
                vim.go.foldmethod = "indent"

                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    vim.fn["repeat"]({ "    L" }, 30)
                )
                Fold.setup_window(winid, bufnr)
                Fold.close_range(bufnr, 5, 15)

                vim.api.nvim_win_call(winid, function()
                    assert.equal(vim.fn.foldclosed(10), 5)
                    assert.equal(vim.fn.foldclosedend(10), 15)
                end)
                assert.equal(vim.wo[winid].foldmethod, "manual")

                vim.go.foldmethod = saved_global
            end
        )
    end)

    describe("close_range", function()
        before_each(function()
            local lines = {}
            for i = 1, 30 do
                lines[i] = "L" .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            Fold.setup_window(winid, bufnr)
        end)

        it("closes a manual fold over the requested range", function()
            Fold.close_range(bufnr, 5, 20)
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(10), 5)
                assert.equal(vim.fn.foldclosed(20), 5)
                assert.equal(vim.fn.foldclosed(21), -1)
            end)
        end)

        it("is a no-op when folding is disabled", function()
            Config.folding = {
                tool_calls = { enabled = false, threshold = 5 },
            }
            Fold.close_range(bufnr, 5, 20)
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(10), -1)
            end)
        end)

        it("is a no-op when start_lnum > end_lnum", function()
            Fold.close_range(bufnr, 20, 5)
            vim.api.nvim_win_call(winid, function()
                assert.equal(vim.fn.foldclosed(10), -1)
            end)
        end)

        it("is a no-op when buffer is not displayed", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(hidden_buf, 0, -1, false, { "a", "b" })

            assert.has_no_errors(function()
                Fold.close_range(hidden_buf, 1, 2)
            end)

            vim.api.nvim_buf_delete(hidden_buf, { force = true })
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
end)
