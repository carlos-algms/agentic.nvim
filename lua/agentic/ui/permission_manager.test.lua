--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local PermissionSection = require("tests.helpers.permission_section")

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
    --- @type TestSpy|nil
    local cmd_spy

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

    --- Write a tool call block so the writer can resolve its permission rows.
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
        if cmd_spy then
            cmd_spy:revert()
            cmd_spy = nil
        end

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

        it("catches up to the bottom when queue drains", function()
            seed_block("tc-1")
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            cmd_spy = spy.on(vim, "cmd")
            pm:resolve("tc-1", "allow-once")

            assert.is_true(cmd_spy:called_with("noautocmd normal! G0zb"))
        end)

        it(
            "does not catch up when focus advances to another request",
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

                cmd_spy = spy.on(vim, "cmd")
                pm:resolve("tc-1", "allow-once")

                assert.is_false(cmd_spy:called_with("noautocmd normal! G0zb"))
            end
        )

        it(
            "jumps the cursor to the first button row of the new focused block on focus change",
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

                pm:_cycle_focus(1)
                assert.equal("tc-2", pm.focused_id)

                local button_row_1 = writer:get_button_row("tc-2", 1)
                assert.is_not_nil(button_row_1)
                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((button_row_1 or 0) + 1, cursor[1])
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
            "cycle_next / cycle_prev jumps cursor to the first button row even with only one pending block",
            function()
                seed_block("tc-only")
                pm:add_request(
                    make_request("tc-only"),
                    spy.new(function() end) --[[@as function]]
                )

                -- Move cursor away from the focused row.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                pm:_cycle_focus(1)

                assert.equal("tc-only", pm.focused_id)
                local button_row_1 = writer:get_button_row("tc-only", 1)
                assert.is_not_nil(button_row_1)
                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((button_row_1 or 0) + 1, cursor[1])
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

        for _, case in ipairs({
            { key = "l", direction = "next" },
            { key = "<Right>", direction = "next" },
            { key = "j", direction = "next" },
            { key = "<Down>", direction = "next" },
            { key = "h", direction = "prev" },
            { key = "<Left>", direction = "prev" },
            { key = "k", direction = "prev" },
            { key = "<Up>", direction = "prev" },
        }) do
            it(
                case.key
                    .. " moves focus to button 2 from index 1 ("
                    .. case.direction
                    .. ") and jumps cursor",
                function()
                    seed_block("tc-1")
                    pm:add_request(
                        make_request("tc-1"),
                        spy.new(function() end) --[[@as function]]
                    )

                    local cb = get_digit_callback(case.key)
                    assert.is_not_nil(cb)
                    if cb then
                        cb()
                    end

                    assert.equal(2, writer:get_focused_button_index("tc-1"))
                    local row_2 = writer:get_button_row("tc-1", 2)
                    assert.is_not_nil(row_2)
                    local cursor = vim.api.nvim_win_get_cursor(winid)
                    assert.equal((row_2 or 0) + 1, cursor[1])

                    -- Second press to disambiguate prev vs next: with 2
                    -- options, a single prev-step from 1 wraps to 2 and
                    -- coincides with next-step. A second step exercises
                    -- the direction-dependent modular wrap.
                    if cb then
                        cb()
                    end
                    assert.equal(1, writer:get_focused_button_index("tc-1"))
                end
            )
        end

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

        it(
            "places cursor on the first button row of the focused block on block focus",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                local button_row_1 = writer:get_button_row("tc-1", 1)
                assert.is_not_nil(button_row_1)

                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((button_row_1 or 0) + 1, cursor[1])
            end
        )

        it(
            "block focus on a block without pending permission falls back to end_row",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )

                pm:resolve("tc-1", "allow-once")
                -- Recompute end_row AFTER resolve: removing button rows
                -- shifts the status row up.

                local end_row = writer:get_block_end_row("tc-1")
                assert.is_not_nil(end_row)

                -- Move cursor away, then call _jump_cursor_to directly.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })
                pm:_jump_cursor_to("tc-1")

                local cursor = vim.api.nvim_win_get_cursor(winid)
                assert.equal((end_row or 0) + 1, cursor[1])
            end
        )

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

        it(
            "all eight cycle keys + <CR> removed when no block is focused",
            function()
                seed_block("tc-1")
                pm:add_request(
                    make_request("tc-1"),
                    spy.new(function() end) --[[@as function]]
                )
                local cycle_keys = {
                    "h",
                    "l",
                    "j",
                    "k",
                    "<Left>",
                    "<Right>",
                    "<Up>",
                    "<Down>",
                }
                for _, lhs in ipairs(cycle_keys) do
                    assert.is_true(has_buf_keymap("n", lhs))
                    -- Also confirm the manager installed a callback, not
                    -- just that something else happens to bind this key.
                    assert.is_not_nil(get_digit_callback(lhs))
                end
                assert.is_true(has_buf_keymap("n", "<CR>"))
                assert.is_not_nil(get_digit_callback("<CR>"))

                pm:resolve("tc-1", "allow-once")

                for _, lhs in ipairs(cycle_keys) do
                    assert.is_false(has_buf_keymap("n", lhs))
                end
                assert.is_false(has_buf_keymap("n", "<CR>"))
            end
        )
    end)

    describe("digit keymap lifecycle", function()
        it("digit 2 submits option 2", function()
            seed_block("tc-1")
            local cb = spy.new(function() end)
            pm:add_request(make_request("tc-1"), cb --[[@as function]])

            local digit_cb = get_digit_callback("2")
            assert.is_not_nil(digit_cb)
            if digit_cb then
                digit_cb()
            end

            assert.spy(cb).was.called(1)
            assert.equal("reject-once", cb.calls[1][1])
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
            local text = PermissionSection.status_row_text(
                bufnr,
                writer:get_block_end_row(tool_call_id) or 0
            )
            assert.is_not_nil(text)
            --- @cast text string
            return text
        end

        --- @param tool_call_id string
        --- @return string[]
        local function button_row_lines(tool_call_id)
            local tracker = writer.tool_call_blocks[tool_call_id]
            --- @cast tracker agentic.ui.MessageWriter.ToolCallBlock
            return PermissionSection.button_row_lines(
                bufnr,
                writer:get_block_end_row(tool_call_id) or 0,
                tracker._rendered_button_count or 0
            )
        end

        for _, case in ipairs({
            {
                name = "strips button rows from the focused block as soon as the user resolves via digit",
                target_id = "tc-only",
                seed = function()
                    seed_block("tc-only")
                    local cb = spy.new(function() end)
                    pm:add_request(
                        make_request("tc-only"),
                        cb --[[@as function]]
                    )
                    return cb
                end,
                resolve = function()
                    local digit_cb = get_digit_callback("1")
                    assert.is_not_nil(digit_cb)
                    if digit_cb then
                        digit_cb()
                    end
                end,
                assert_callback_fired = true,
            },
            {
                name = "strips button rows from a non-focused block when it is resolved",
                target_id = "tc-2",
                seed = function()
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
                end,
                resolve = function()
                    pm:resolve("tc-2", nil)
                end,
                assert_callback_fired = false,
            },
        }) do
            it(case.name, function()
                local cb = case.seed()

                local rows_before = button_row_lines(case.target_id)
                assert.is_true(#rows_before > 0)

                case.resolve()

                if case.assert_callback_fired then
                    assert.spy(cb).was.called(1)
                end
                assert.equal(0, #button_row_lines(case.target_id))
                local text = status_row_text(case.target_id)
                assert.is_nil(text:find("Allow"))
                assert.is_nil(text:find("Reject"))
            end)
        end
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
