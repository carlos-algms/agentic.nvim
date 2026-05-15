--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.PermissionManager", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type agentic.ui.PermissionManager
    local PermissionManager
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.MessageWriter
    local writer
    --- @type agentic.ui.PermissionManager
    local pm
    --- @type TestStub
    local schedule_stub

    --- Build a permission request with the given tool_call_id. Defaults to
    --- one allow_once + one reject_once option; pass opts.options to override.
    --- @param tool_call_id string
    --- @param opts { options?: agentic.acp.PermissionOption[] }|nil
    --- @return agentic.acp.RequestPermission
    local function make_request(tool_call_id, opts)
        local options = opts and opts.options
            or {
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
            }
        return {
            sessionId = "test-session",
            toolCall = { toolCallId = tool_call_id },
            options = options,
        }
    end

    --- Write a tool call block so the writer can resolve its row N.
    --- @param tool_call_id string
    local function seed_block(tool_call_id)
        writer:write_tool_call_block({
            tool_call_id = tool_call_id,
            status = "pending",
            kind = "execute",
            argument = "ls",
            body = { "output" },
        })
    end

    --- @param mode string
    --- @param lhs string
    --- @return boolean
    local function has_buf_keymap(mode, lhs)
        for _, km in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
            if km.lhs == lhs then
                return true
            end
        end
        return false
    end

    --- @param lhs string
    --- @return function|nil
    local function get_digit_callback(lhs)
        for _, km in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
            if km.lhs == lhs then
                return km.callback
            end
        end
        return nil
    end

    before_each(function()
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            fn()
        end)

        MessageWriter = require("agentic.ui.message_writer")
        PermissionManager = require("agentic.ui.permission_manager")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
        pm = PermissionManager:new(writer)
    end)

    after_each(function()
        schedule_stub:revert()

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("concurrent pending map", function()
        it(
            "keeps both requests in pending and preserves insertion order",
            function()
                seed_block("tc-a")
                seed_block("tc-b")

                pm:add_request(
                    make_request("tc-a"),
                    spy.new(function() end) --[[@as function]]
                )
                pm:add_request(
                    make_request("tc-b"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.is_not_nil(pm.pending["tc-a"])
                assert.is_not_nil(pm.pending["tc-b"])
                assert.equal("tc-a", pm._order[1])
                assert.equal("tc-b", pm._order[2])
                assert.is_true(pm:has_pending())
            end
        )

        it(
            "fires only the matching callback on resolve and leaves others pending",
            function()
                seed_block("tc-a")
                seed_block("tc-b")

                local cb_a = spy.new(function() end)
                local cb_b = spy.new(function() end)

                pm:add_request(make_request("tc-a"), cb_a --[[@as function]])
                pm:add_request(make_request("tc-b"), cb_b --[[@as function]])

                pm:resolve("tc-a", "allow-once")

                assert.spy(cb_a).was.called(1)
                assert.spy(cb_b).was.called(0)
                assert.is_nil(pm.pending["tc-a"])
                assert.is_not_nil(pm.pending["tc-b"])
            end
        )

        it("supports out-of-order resolution", function()
            seed_block("tc-a")
            seed_block("tc-b")

            local cb_a = spy.new(function() end)
            local cb_b = spy.new(function() end)

            pm:add_request(make_request("tc-a"), cb_a --[[@as function]])
            pm:add_request(make_request("tc-b"), cb_b --[[@as function]])

            pm:resolve("tc-b", "reject-once")

            assert.spy(cb_b).was.called(1)
            assert.spy(cb_a).was.called(0)
            assert.is_not_nil(pm.pending["tc-a"])
            assert.is_nil(pm.pending["tc-b"])
        end)
    end)

    describe("focus head tracking", function()
        it(
            "first arrival sets focused_id and installs digit keymaps",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.equal("tc-1", pm.focused_id)
                assert.is_true(has_buf_keymap("n", "1"))
                assert.is_true(has_buf_keymap("n", "2"))
            end
        )

        it("subsequent arrivals do not steal focus", function()
            seed_block("tc-1")
            seed_block("tc-2")

            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            assert.equal("tc-1", pm.focused_id)
        end)

        it("resolving the focused request snaps focus to next head", function()
            seed_block("tc-1")
            seed_block("tc-2")

            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            pm:resolve("tc-1", "allow-once")

            assert.equal("tc-2", pm.focused_id)
        end)

        it(
            "clears focus and removes digit keymaps when queue drains",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )
                assert.is_true(has_buf_keymap("n", "1"))

                pm:resolve("tc-1", "allow-once")

                assert.is_nil(pm.focused_id)
                assert.is_false(has_buf_keymap("n", "1"))
                assert.is_false(has_buf_keymap("n", "2"))
            end
        )

        it(
            "jumps the cursor to row N of the new focused block on focus change",
            function()
                seed_block("tc-1")
                seed_block("tc-2")

                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )
                pm:add_request(
                    make_request("tc-2"),
                    spy.new(function() end) --[[@as function]]
                )

                local end_row_2 = writer:get_block_end_row("tc-2")
                assert.is_not_nil(end_row_2)

                pm:_cycle_focus(1)
                assert.equal("tc-2", pm.focused_id)

                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal(end_row_2 + 1, cursor[1])
            end
        )
    end)

    describe("bracket cycle", function()
        it(
            "installs cycle keymaps only while permissions are pending",
            function()
                assert.is_false(has_buf_keymap("n", "<C-N>"))
                assert.is_false(has_buf_keymap("n", "<C-P>"))

                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.is_true(has_buf_keymap("n", "<C-N>"))
                assert.is_true(has_buf_keymap("n", "<C-P>"))

                pm:resolve("tc-1", "allow-once")

                assert.is_false(has_buf_keymap("n", "<C-N>"))
                assert.is_false(has_buf_keymap("n", "<C-P>"))
            end
        )

        it("forward cycle wraps to first", function()
            seed_block("tc-1")
            seed_block("tc-2")
            seed_block("tc-3")

            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-3"),
                spy.new(function() end) --[[@as function]]
            )

            pm:_cycle_focus(1)
            assert.equal("tc-2", pm.focused_id)
            pm:_cycle_focus(1)
            assert.equal("tc-3", pm.focused_id)
            pm:_cycle_focus(1)
            assert.equal("tc-1", pm.focused_id)
        end)

        it("backward cycle wraps to last", function()
            seed_block("tc-1")
            seed_block("tc-2")
            seed_block("tc-3")

            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-3"),
                spy.new(function() end) --[[@as function]]
            )

            pm:_cycle_focus(-1)
            assert.equal("tc-3", pm.focused_id)
            pm:_cycle_focus(-1)
            assert.equal("tc-2", pm.focused_id)
        end)

        it(
            "cycle_next / cycle_prev jumps cursor to the focused row even with only one pending block",
            function()
                seed_block("tc-only")
                pm:add_request(
                    make_request("tc-only"),
                    spy.new(function() end) --[[@as function]]
                )

                local end_row = writer:get_block_end_row("tc-only")
                local first_btn_col = writer:get_button_col("tc-only", 1)
                assert.is_not_nil(end_row)

                -- Move cursor away from the focused row.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                pm:_cycle_focus(1)

                assert.equal("tc-only", pm.focused_id)
                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((end_row or 0) + 1, cursor[1])
                assert.equal(first_btn_col, cursor[2])
            end
        )

        it("cycle is a no-op when pending is empty", function()
            assert.has_no_errors(function()
                pm:_cycle_focus(1)
                pm:_cycle_focus(-1)
            end)
            assert.is_nil(pm.focused_id)
        end)

        it("focus transition triggers exactly 2 status-row repaints", function()
            seed_block("tc-1")
            seed_block("tc-2")

            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            local repaint_spy = spy.on(writer, "repaint_status_row")
            pm:_cycle_focus(1)

            assert.equal(2, repaint_spy.call_count)
            local ids = {}
            for _, call in ipairs(repaint_spy.calls) do
                ids[call[2]] = true
            end
            assert.is_true(ids["tc-1"])
            assert.is_true(ids["tc-2"])

            repaint_spy:revert()
        end)
    end)

    describe("button-level focus (h / l / <CR>)", function()
        it(
            "resets focused_button_index to 1 on each block focus change",
            function()
                seed_block("tc-1")
                seed_block("tc-2")

                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )
                pm:add_request(
                    make_request("tc-2"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.equal(1, writer:get_focused_button_index("tc-1"))

                local l_cb = get_digit_callback("l")
                assert.is_not_nil(l_cb)
                if l_cb then
                    l_cb()
                end
                assert.equal(2, writer:get_focused_button_index("tc-1"))

                -- Cycle block focus; new focused block must start at 1.
                pm:_cycle_focus(1)
                assert.equal("tc-2", pm.focused_id)
                assert.equal(1, writer:get_focused_button_index("tc-2"))
            end
        )

        it("l cycles button focus forward and wraps", function()
            seed_block("tc-1")
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            local l_cb = get_digit_callback("l")
            assert.is_not_nil(l_cb)
            if l_cb then
                l_cb()
                assert.equal(2, writer:get_focused_button_index("tc-1"))
                l_cb() -- cycles back to 1 (only 2 options)
                assert.equal(1, writer:get_focused_button_index("tc-1"))
            end
        end)

        it(
            "l moves cursor to the start col of the newly focused button",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                local end_row = writer:get_block_end_row("tc-1")
                assert.is_not_nil(end_row)

                local l_cb = get_digit_callback("l")
                assert.is_not_nil(l_cb)
                if l_cb then
                    l_cb()
                end

                local expected_col = writer:get_button_col("tc-1", 2)
                assert.is_not_nil(expected_col)
                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((end_row or 0) + 1, cursor[1])
                assert.equal(expected_col, cursor[2])
            end
        )

        it("h cycles button focus backward and wraps", function()
            seed_block("tc-1")
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            local h_cb = get_digit_callback("h")
            assert.is_not_nil(h_cb)
            if h_cb then
                h_cb() -- wraps from 1 to last (2)
                assert.equal(2, writer:get_focused_button_index("tc-1"))
                h_cb()
                assert.equal(1, writer:get_focused_button_index("tc-1"))
            end
        end)

        it(
            "<CR> resolves the focused block with focused button's option",
            function()
                seed_block("tc-1")
                local cb = spy.new(function() end)
                pm:add_request(make_request("tc-1"), cb --[[@as function]])

                local l_cb = get_digit_callback("l")
                local cr_cb = get_digit_callback("<CR>")
                assert.is_not_nil(l_cb)
                assert.is_not_nil(cr_cb)
                if l_cb then
                    l_cb()
                end
                if cr_cb then
                    cr_cb()
                end

                assert.spy(cb).was.called(1)
                assert.equal("reject-once", cb.calls[1][1])
            end
        )

        it("places cursor on first button column on block focus", function()
            seed_block("tc-1")
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            local end_row = writer:get_block_end_row("tc-1")
            local first_btn_col = writer:get_button_col("tc-1", 1)
            assert.is_not_nil(end_row)
            assert.is_not_nil(first_btn_col)
            assert.is_true((first_btn_col or 0) > 0)

            local cursor = vim.api.nvim_win_get_cursor(winid)
            assert.equal((end_row or 0) + 1, cursor[1])
            assert.equal(first_btn_col, cursor[2])
        end)

        it(
            "<Left> / <Right> are installed and cycle button focus when on row",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                local right_cb = get_digit_callback("<Right>")
                local left_cb = get_digit_callback("<Left>")
                assert.is_not_nil(right_cb)
                assert.is_not_nil(left_cb)
                if right_cb then
                    right_cb()
                    assert.equal(2, writer:get_focused_button_index("tc-1"))
                end
                if left_cb then
                    left_cb()
                    assert.equal(1, writer:get_focused_button_index("tc-1"))
                end
            end
        )

        it(
            "motion / submit keymaps fall through when cursor is off the focused row",
            function()
                seed_block("tc-1")
                local cb = spy.new(function() end)
                pm:add_request(make_request("tc-1"), cb --[[@as function]])

                -- Move cursor off the focused row.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                local l_cb = get_digit_callback("l")
                local cr_cb = get_digit_callback("<CR>")
                assert.is_not_nil(l_cb)
                assert.is_not_nil(cr_cb)

                -- expr=true: returning the original key falls through to default behavior.
                if l_cb then
                    assert.equal("l", l_cb())
                end
                if cr_cb then
                    assert.equal("<CR>", cr_cb())
                end

                -- No resolve fired, button index unchanged.
                assert.spy(cb).was.called(0)
                assert.equal(1, writer:get_focused_button_index("tc-1"))
            end
        )

        it(
            "digit keymaps fire from anywhere in the chat buffer (off-row included)",
            function()
                seed_block("tc-1")
                local cb = spy.new(function() end)
                pm:add_request(make_request("tc-1"), cb --[[@as function]])

                -- Move cursor off the focused row.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                local digit_cb = get_digit_callback("1")
                assert.is_not_nil(digit_cb)
                if digit_cb then
                    digit_cb()
                end

                assert.spy(cb).was.called(1)
                assert.equal("allow-once", cb.calls[1][1])
            end
        )

        it("h / l / <CR> removed when no block is focused", function()
            seed_block("tc-1")
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )
            assert.is_true(has_buf_keymap("n", "h"))
            assert.is_true(has_buf_keymap("n", "l"))
            assert.is_true(has_buf_keymap("n", "<CR>"))

            pm:resolve("tc-1", "allow-once")

            assert.is_false(has_buf_keymap("n", "h"))
            assert.is_false(has_buf_keymap("n", "l"))
            assert.is_false(has_buf_keymap("n", "<CR>"))
        end)
    end)

    describe("digit keymap lifecycle", function()
        it("digit 1 resolves the focused block's option 1", function()
            seed_block("tc-1")
            local cb = spy.new(function() end)
            pm:add_request(make_request("tc-1"), cb --[[@as function]])

            local digit_cb = get_digit_callback("1")
            assert.is_not_nil(digit_cb)
            if digit_cb then
                digit_cb()
            end

            assert.spy(cb).was.called(1)
            assert.equal("allow-once", cb.calls[1][1])
        end)

        it(
            "rebinds digit keymaps with new mapping after focus transition",
            function()
                seed_block("tc-1")
                seed_block("tc-2")

                local cb_1 = spy.new(function() end)
                local cb_2 = spy.new(function() end)

                pm:add_request(
                    make_request("tc-1", {
                        options = {
                            {
                                optionId = "opt-1-A",
                                name = "A",
                                kind = "allow_once",
                            },
                            {
                                optionId = "opt-1-B",
                                name = "B",
                                kind = "reject_once",
                            },
                        },
                    }),
                    cb_1 --[[@as function]]
                )
                pm:add_request(
                    make_request("tc-2", {
                        options = {
                            {
                                optionId = "opt-2-A",
                                name = "A",
                                kind = "allow_once",
                            },
                            {
                                optionId = "opt-2-B",
                                name = "B",
                                kind = "reject_once",
                            },
                        },
                    }),
                    cb_2 --[[@as function]]
                )

                pm:_cycle_focus(1)
                assert.equal("tc-2", pm.focused_id)

                local digit_cb = get_digit_callback("1")
                assert.is_not_nil(digit_cb)
                if digit_cb then
                    digit_cb()
                end

                assert.spy(cb_2).was.called(1)
                assert.equal("opt-2-A", cb_2.calls[1][1])
                assert.spy(cb_1).was.called(0)
            end
        )
    end)

    describe("clear", function()
        it("fires all pending callbacks with nil and clears state", function()
            seed_block("tc-1")
            seed_block("tc-2")

            local cb_1 = spy.new(function() end)
            local cb_2 = spy.new(function() end)

            pm:add_request(make_request("tc-1"), cb_1 --[[@as function]])
            pm:add_request(make_request("tc-2"), cb_2 --[[@as function]])

            pm:clear()

            assert.spy(cb_1).was.called(1)
            assert.spy(cb_2).was.called(1)
            assert.is_nil(cb_1.calls[1][1])
            assert.is_nil(cb_2.calls[1][1])
            assert.is_nil(pm.focused_id)
            assert.is_false(pm:has_pending())
            assert.is_false(has_buf_keymap("n", "1"))
            assert.is_false(has_buf_keymap("n", "<C-N>"))
            assert.is_false(has_buf_keymap("n", "<C-P>"))
        end)
    end)

    describe("resolve hygiene", function()
        --- @param tool_call_id string
        --- @return string
        local function status_row_text(tool_call_id)
            local row = writer:get_block_end_row(tool_call_id) or 0
            return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
                or ""
        end

        it("strips buttons from row N as soon as the user resolves", function()
            seed_block("tc-only")
            local cb = spy.new(function() end)
            pm:add_request(make_request("tc-only"), cb --[[@as function]])

            assert.truthy(status_row_text("tc-only"):find("Allow"))

            local digit_cb = get_digit_callback("1")
            assert.is_not_nil(digit_cb)
            if digit_cb then
                digit_cb()
            end

            assert.spy(cb).was.called(1)
            local text = status_row_text("tc-only")
            assert.is_nil(text:find("Allow"))
            assert.is_nil(text:find("Reject"))
            assert.truthy(text:find("pending"))
        end)

        it(
            "strips buttons from a non-focused block when it is resolved",
            function()
                seed_block("tc-1")
                seed_block("tc-2")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )
                pm:add_request(
                    make_request("tc-2"),
                    spy.new(function() end) --[[@as function]]
                )

                pm:resolve("tc-2", nil)

                local text = status_row_text("tc-2")
                assert.is_nil(text:find("Allow"))
                assert.is_nil(text:find("Reject"))
            end
        )
    end)

    describe("remove_request_by_tool_call_id", function()
        it("fires the callback with nil and advances focus", function()
            seed_block("tc-1")
            seed_block("tc-2")

            local cb_1 = spy.new(function() end)
            local cb_2 = spy.new(function() end)

            pm:add_request(make_request("tc-1"), cb_1 --[[@as function]])
            pm:add_request(make_request("tc-2"), cb_2 --[[@as function]])

            pm:remove_request_by_tool_call_id("tc-1")

            assert.spy(cb_1).was.called(1)
            assert.is_nil(cb_1.calls[1][1])
            assert.spy(cb_2).was.called(0)
            assert.equal("tc-2", pm.focused_id)
        end)
    end)
end)
