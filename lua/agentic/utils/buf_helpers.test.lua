local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("BufHelpers", function()
    --- @type agentic.utils.BufHelpers
    local BufHelpers

    before_each(function()
        BufHelpers = require("agentic.utils.buf_helpers")
    end)

    describe("with_modifiable", function()
        it("should allow writing to non-modifiable buffer", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            local ok, err = pcall(function()
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "should fail" }
                )
            end)
            assert.is_false(ok)
            assert.is_not_nil(err)

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(1, #lines)
            assert.are.equal("hello world", lines[1])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should handle nested with_modifiable calls", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line" })

                BufHelpers.with_modifiable(buf, function(inner_buf)
                    vim.api.nvim_buf_set_lines(
                        inner_buf,
                        -1,
                        -1,
                        false,
                        { "second line" }
                    )
                end)

                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "third line" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(3, #lines)
            assert.are.equal("first line", lines[1])
            assert.are.equal("second line", lines[2])
            assert.are.equal("third line", lines[3])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("execute_on_buffer", function()
        it("should return nil for invalid buffer number", function()
            local result = BufHelpers.execute_on_buffer(9999, function(_buf)
                return "should not execute"
            end)

            assert.is_nil(result)
        end)

        it(
            "should execute callback with buffer number and return value",
            function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                local expected_return = { value = 42, text = "test" }
                local callback_spy = spy.new(function(_buf)
                    return expected_return
                end)

                ---@diagnostic disable-next-line: param-type-mismatch spy won't match the expected type
                local result = BufHelpers.execute_on_buffer(bufnr, callback_spy)

                assert.spy(callback_spy).was.called(1)
                assert.spy(callback_spy).was.called_with(bufnr)
                assert.are.same(expected_return, result)

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )
    end)

    describe("keymap_set", function()
        --- @type TestStub
        local keymap_set_stub
        --- @type TestStub
        local has_stub

        before_each(function()
            keymap_set_stub = spy.stub(vim.keymap, "set")
            has_stub = spy.stub(vim.fn, "has")
        end)

        after_each(function()
            keymap_set_stub:revert()
            has_stub:revert()
        end)

        -- Regression: 0.12.0-dev nightlies built before neovim#38360 (`buffer`
        -- -> `buf` rename) report `has('nvim-0.12') == 1` but reject `buf` with
        -- `invalid key: buf`. Gate on 0.12.1, first stable shipping `buf`.
        it("uses `buffer` opt on Neovim < 0.12.1", function()
            has_stub:invokes(function(feature)
                return feature == "nvim-0.12.1" and 0 or 1
            end)
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.keymap_set(bufnr, "n", "x", function() end)

            local opts = keymap_set_stub.calls[1][4]
            assert.equal(bufnr, opts.buffer)
            assert.is_nil(opts.buf)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("uses `buf` opt on Neovim >= 0.12.1", function()
            has_stub:invokes(function(feature)
                return feature == "nvim-0.12.1" and 1 or 0
            end)
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.keymap_set(bufnr, "n", "x", function() end)

            local opts = keymap_set_stub.calls[1][4]
            assert.equal(bufnr, opts.buf)
            assert.is_nil(opts.buffer)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("keymap_del", function()
        --- @type TestStub
        local keymap_del_stub
        --- @type TestStub
        local has_stub

        before_each(function()
            keymap_del_stub = spy.stub(vim.keymap, "del")
            has_stub = spy.stub(vim.fn, "has")
        end)

        after_each(function()
            keymap_del_stub:revert()
            has_stub:revert()
        end)

        -- 0.12.0-dev / 0.12.1 rename rationale: see keymap_set tests.
        it("uses `buffer` opt on Neovim < 0.12.1", function()
            has_stub:invokes(function(feature)
                return feature == "nvim-0.12.1" and 0 or 1
            end)
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.keymap_del(bufnr, "n", "x")

            local opts = keymap_del_stub.calls[1][3]
            assert.equal(bufnr, opts.buffer)
            assert.is_nil(opts.buf)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("uses `buf` opt on Neovim >= 0.12.1", function()
            has_stub:invokes(function(feature)
                return feature == "nvim-0.12.1" and 1 or 0
            end)
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.keymap_del(bufnr, "n", "x")

            local opts = keymap_del_stub.calls[1][3]
            assert.equal(bufnr, opts.buf)
            assert.is_nil(opts.buffer)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("multi_keymap_del", function()
        --- @type TestStub
        local keymap_del_stub
        --- @type TestStub
        local has_stub

        before_each(function()
            keymap_del_stub = spy.stub(vim.keymap, "del")
            has_stub = spy.stub(vim.fn, "has")
            has_stub:returns(1)
        end)

        after_each(function()
            keymap_del_stub:revert()
            has_stub:revert()
        end)

        it("deletes a single string keymap", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.multi_keymap_del("x", bufnr)

            assert.equal(1, keymap_del_stub.call_count)
            assert.equal("n", keymap_del_stub.calls[1][1])
            assert.equal("x", keymap_del_stub.calls[1][2])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("deletes array entries with configured modes", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            BufHelpers.multi_keymap_del({
                "x",
                { "y", mode = "i" },
            }, bufnr)

            assert.equal(2, keymap_del_stub.call_count)
            assert.equal("n", keymap_del_stub.calls[1][1])
            assert.equal("x", keymap_del_stub.calls[1][2])
            assert.equal("i", keymap_del_stub.calls[2][1])
            assert.equal("y", keymap_del_stub.calls[2][2])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("win_set_width / win_set_height", function()
        local winid

        before_each(function()
            vim.cmd("tabnew")
            vim.cmd("vsplit")
            winid = vim.api.nvim_get_current_win()
        end)

        after_each(function()
            pcall(function()
                vim.cmd("tabclose!")
            end)
        end)

        it("resizes the window width on the running Neovim", function()
            BufHelpers.win_set_width(winid, 20)

            assert.equal(20, vim.api.nvim_win_get_width(winid))
        end)

        it("resizes the window height on the running Neovim", function()
            BufHelpers.win_set_height(winid, 8)

            assert.equal(8, vim.api.nvim_win_get_height(winid))
        end)

        it("leaves the other axis untouched", function()
            local original_height = vim.api.nvim_win_get_height(winid)

            BufHelpers.win_set_width(winid, 20)

            assert.equal(original_height, vim.api.nvim_win_get_height(winid))
        end)

        -- `nvim_win_set_width`/`_set_height` are deprecated on nightly for
        -- `nvim_win_resize`, which only exists on 0.13+. CI runs a nightly
        -- matrix job, so both branches stay reachable on every version.
        -- `spy.stub` cannot restore an absent field, so the 0.13 branch uses a
        -- saved original cleared by hand.
        it("calls nvim_win_resize on Neovim >= 0.13", function()
            local has_stub = spy.stub(vim.fn, "has")
            has_stub:invokes(function(feature)
                return feature == "nvim-0.13" and 1 or 0
            end)

            local original_resize = vim.api.nvim_win_resize
            local calls = {}
            --- @diagnostic disable-next-line: inject-field, duplicate-set-field
            vim.api.nvim_win_resize = function(win, width, height, opts)
                calls[#calls + 1] = { win, width, height, opts }
            end

            BufHelpers.win_set_width(winid, 20)
            BufHelpers.win_set_height(winid, 8)

            --- @diagnostic disable-next-line: inject-field
            vim.api.nvim_win_resize = original_resize
            has_stub:revert()

            assert.equal(2, #calls)
            assert.equal(winid, calls[1][1])
            assert.equal(20, calls[1][2])
            assert.equal(-1, calls[1][3])
            assert.equal(-1, calls[2][2])
            assert.equal(8, calls[2][3])
        end)

        it("falls back to the single-axis setters on Neovim < 0.13", function()
            local has_stub = spy.stub(vim.fn, "has")
            has_stub:returns(0)
            --- @diagnostic disable-next-line: deprecated
            local set_width_stub = spy.stub(vim.api, "nvim_win_set_width")
            --- @diagnostic disable-next-line: deprecated
            local set_height_stub = spy.stub(vim.api, "nvim_win_set_height")

            BufHelpers.win_set_width(winid, 20)

            set_width_stub:revert()
            set_height_stub:revert()
            has_stub:revert()

            assert.equal(1, set_width_stub.call_count)
            assert.equal(winid, set_width_stub.calls[1][1])
            assert.equal(20, set_width_stub.calls[1][2])
            -- Unset axis passes -1 and must not reach the setter.
            assert.equal(0, set_height_stub.call_count)
        end)
    end)

    describe("is_buffer_empty", function()
        it("should return true for buffer with single empty line", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for single line with only whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  \t  " })

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for multiple lines all whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "\t", "", "  \t  " }
            )

            assert.is_true(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for buffer with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

            assert.is_false(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for multiple lines with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "", "text", "  " }
            )

            assert.is_false(BufHelpers.is_buffer_empty(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("find_visible_win", function()
        local bufnr
        local base_tabs

        before_each(function()
            base_tabs = #vim.api.nvim_list_tabpages()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            while #vim.api.nvim_list_tabpages() > base_tabs do
                local ok = pcall(function()
                    vim.cmd("tabclose!")
                end)
                if not ok then
                    break
                end
            end
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("returns nil when no window shows the buffer", function()
            assert.is_nil(BufHelpers.find_visible_win(bufnr))
        end)

        it("finds a window in another tabpage", function()
            vim.cmd("tabnew")
            local other_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(other_win, bufnr)
            vim.cmd("tabprevious")

            -- `vim.fn.bufwinid`, which this replaced, returns -1 here: it "Only
            -- deals with the current tabpage".
            assert.equal(other_win, BufHelpers.find_visible_win(bufnr))
        end)

        it("ignores a hidden, non-focusable float", function()
            local winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 5,
                height = 2,
                focusable = false,
                hide = true,
            })

            -- Measured: the old lookup returned this float, so a widget's hidden
            -- chat float absorbed a winbar nobody sees.
            assert.is_nil(BufHelpers.find_visible_win(bufnr))

            pcall(vim.api.nvim_win_close, winid, true)
        end)

        it("ignores a focusable float that is hidden", function()
            -- `focusable` alone is not the predicate; `hide` is.
            local winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 5,
                height = 2,
                focusable = true,
                hide = true,
            })

            assert.is_nil(BufHelpers.find_visible_win(bufnr))

            pcall(vim.api.nvim_win_close, winid, true)
        end)

        it("prefers the caller's own window over another tab's", function()
            vim.cmd("tabnew")
            local foreign_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(foreign_win, bufnr)

            vim.cmd("tabnew")
            local own_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(own_win, bufnr)

            assert.equal(own_win, BufHelpers.find_visible_win(bufnr, own_win))
        end)

        it(
            "ignores a preferred window that no longer shows the buffer",
            function()
                vim.cmd("tabnew")
                local real_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(real_win, bufnr)

                local stale_win = vim.api.nvim_open_win(
                    vim.api.nvim_create_buf(false, true),
                    false,
                    { split = "below", win = real_win }
                )

                assert.equal(
                    real_win,
                    BufHelpers.find_visible_win(bufnr, stale_win)
                )
            end
        )

        it(
            "rejects a preferred window outside the requested tabpage",
            function()
                vim.cmd("tabnew")
                local foreign_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(foreign_win, bufnr)

                vim.cmd("tabnew")
                local wanted_tab = vim.api.nvim_get_current_tabpage()
                local wanted_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(wanted_win, bufnr)

                -- Preferred window still shows the buffer, so only the tab
                -- filter can reject it.
                assert.equal(
                    wanted_win,
                    BufHelpers.find_visible_win(bufnr, foreign_win, wanted_tab)
                )
            end
        )

        it("restricts the search to a given tabpage", function()
            vim.cmd("tabnew")
            local first_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(first_win, bufnr)

            vim.cmd("tabnew")
            local second_tab = vim.api.nvim_get_current_tabpage()
            local second_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(second_win, bufnr)

            -- Same file open in two tabs must resolve to the session's own.
            assert.equal(
                second_win,
                BufHelpers.find_visible_win(bufnr, nil, second_tab)
            )
        end)

        it(
            "falls back across tabpages when the preferred window is stale",
            function()
                vim.cmd("tabnew")
                local foreign_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(foreign_win, bufnr)

                vim.cmd("tabnew")
                local stale_win = vim.api.nvim_get_current_win()

                -- Preferred window no longer shows the buffer and its own tab
                -- has no other holder: only a cross-tab fallback resolves the
                -- foreign session's window. An unscoped call must not be nil.
                assert.equal(
                    foreign_win,
                    BufHelpers.find_visible_win(bufnr, stale_win)
                )
            end
        )

        it(
            "returns nil when the buffer is visible in no other tabpage",
            function()
                vim.cmd("tabnew")
                local win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(win, bufnr)
                local empty_tab = vim.api.nvim_get_current_tabpage()

                vim.cmd("tabnew")

                assert.is_nil(
                    BufHelpers.find_visible_win(
                        bufnr,
                        nil,
                        vim.api.nvim_get_current_tabpage()
                    )
                )
                assert.equal(
                    win,
                    BufHelpers.find_visible_win(bufnr, nil, empty_tab)
                )
            end
        )
    end)

    describe("is_win_usable", function()
        local base_tabs

        before_each(function()
            base_tabs = #vim.api.nvim_list_tabpages()
        end)

        after_each(function()
            while #vim.api.nvim_list_tabpages() > base_tabs do
                local ok = pcall(function()
                    vim.cmd("tabclose!")
                end)
                if not ok then
                    break
                end
            end
        end)

        it("returns true for a window in a live tabpage", function()
            vim.cmd("tabnew")

            assert.is_true(
                BufHelpers.is_win_usable(vim.api.nvim_get_current_win())
            )
        end)

        it("returns false for an unknown handle", function()
            assert.is_false(BufHelpers.is_win_usable(99999))
        end)

        it("returns false for a closed window", function()
            vim.cmd("tabnew")
            local winid = vim.api.nvim_get_current_win()
            vim.cmd("tabnew")
            pcall(vim.api.nvim_win_close, winid, true)

            assert.is_false(BufHelpers.is_win_usable(winid))
        end)

        -- On 0.11.x `tabclose` leaves handles still valid per
        -- `nvim_win_is_valid`; `nvim_win_close` on one segfaults. The tabpage is
        -- the only axis rejecting it. Stubbed: stale-valid is platform-specific.
        it("returns false for a valid window whose tabpage is gone", function()
            vim.cmd("tabnew")
            local winid = vim.api.nvim_get_current_win()
            local dead_tab = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabclose!")

            local valid_stub = spy.stub(vim.api, "nvim_win_is_valid")
            valid_stub:returns(true)
            local tabpage_stub = spy.stub(vim.api, "nvim_win_get_tabpage")
            tabpage_stub:returns(dead_tab)

            local usable = BufHelpers.is_win_usable(winid)

            valid_stub:revert()
            tabpage_stub:revert()

            assert.is_false(usable)
        end)
    end)
end)
