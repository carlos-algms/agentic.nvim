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
    --- @type TestStub
    local hint_stub
    --- @type TestStub
    local hint_style_stub

    --- @return agentic.acp.RequestPermission
    local function make_request(tool_call_id)
        return {
            sessionId = "test-session",
            toolCall = {
                toolCallId = tool_call_id,
            },
            options = {
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
            },
        }
    end

    local function inject_content_and_reanchor()
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(
            bufnr,
            -1,
            -1,
            false,
            { "new tool call output line 1", "new tool call output line 2" }
        )
        vim.bo[bufnr].modifiable = false
        writer:_notify_content_changed()
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

    before_each(function()
        schedule_stub = spy.stub(vim, "schedule")

        local DiffPreview = require("agentic.ui.diff_preview")
        hint_stub = spy.stub(DiffPreview, "add_navigation_hint")
        hint_stub:returns(nil)
        hint_style_stub = spy.stub(DiffPreview, "apply_hint_styling")

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
        hint_stub:revert()
        hint_style_stub:revert()

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("reanchor permission prompt", function()
        it("moves buttons to buffer bottom and preserves keymaps", function()
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            local line_count_before = vim.api.nvim_buf_line_count(bufnr)
            inject_content_and_reanchor()
            local line_count_after = vim.api.nvim_buf_line_count(bufnr)

            assert.is_true(line_count_after > line_count_before)

            local last_lines = vim.api.nvim_buf_get_lines(bufnr, -3, -1, false)
            local found_permission = false
            for _, line in ipairs(last_lines) do
                if line:find("Allow once") or line:find("--- ---") then
                    found_permission = true
                    break
                end
            end
            assert.is_true(found_permission)

            assert.is_true(has_buf_keymap("n", "1"))
            assert.is_true(has_buf_keymap("n", "2"))
        end)

        it("does not trigger recursive on_content_changed", function()
            local notify_spy = spy.on(writer, "_notify_content_changed")

            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            notify_spy:reset()
            writer:_notify_content_changed()

            assert.equal(1, notify_spy.call_count)

            notify_spy:revert()
        end)
    end)

    describe("callback lifecycle", function()
        it("_complete_request clears the content changed callback", function()
            pm:add_request(
                make_request("tc-3"),
                spy.new(function() end) --[[@as function]]
            )

            pm:_complete_request("allow-once")

            assert.is_nil(writer._on_content_changed)
        end)

        it("clear() clears the content changed callback", function()
            pm:add_request(
                make_request("tc-4"),
                spy.new(function() end) --[[@as function]]
            )

            pm:clear()

            assert.is_nil(writer._on_content_changed)
        end)
    end)

    describe("empty line accumulation during reanchor", function()
        --- @return string[]
        local function get_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- @return integer
        local function count_trailing_empty_lines()
            local lines = get_lines()
            local count = 0
            for i = #lines, 1, -1 do
                if lines[i] == "" then
                    count = count + 1
                else
                    break
                end
            end
            return count
        end

        it(
            "single display+remove leaves exactly one trailing separator",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                local lines_before = vim.api.nvim_buf_line_count(bufnr)

                pm:add_request(
                    make_request("tc-sep-1"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.is_true(
                    vim.api.nvim_buf_line_count(bufnr) > lines_before
                )

                pm:_complete_request("allow-once")

                -- remove_permission_buttons replaces the block with {""},
                -- so buffer should be original lines + 1 separator
                assert.equal(
                    lines_before + 1,
                    vim.api.nvim_buf_line_count(bufnr)
                )
                assert.equal(1, count_trailing_empty_lines())
            end
        )

        it(
            "does not accumulate empty lines across multiple reanchors",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                pm:add_request(
                    make_request("tc-accum-1"),
                    spy.new(function() end) --[[@as function]]
                )

                -- Simulate 5 reanchor cycles (new content triggers reanchor)
                for _ = 1, 5 do
                    inject_content_and_reanchor()
                end

                pm:_complete_request("allow-once")

                -- Should have exactly 1 trailing empty line, not 1 per cycle
                assert.equal(1, count_trailing_empty_lines())
            end
        )

        it(
            "reanchor preserves single separator between content and buttons",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                pm:add_request(
                    make_request("tc-sep-2"),
                    spy.new(function() end) --[[@as function]]
                )

                -- Reanchor once
                inject_content_and_reanchor()

                -- Find last injected content line, then count empty lines after it
                local lines = get_lines()
                local last_content_idx = 0
                for i = 1, #lines do
                    if lines[i]:find("new tool call output") then
                        last_content_idx = i
                    end
                end
                assert.is_true(last_content_idx > 0)

                local empty_count = 0
                for i = last_content_idx + 1, #lines do
                    if lines[i] == "" then
                        empty_count = empty_count + 1
                    else
                        break
                    end
                end
                assert.equal(1, empty_count)

                pm:_complete_request("allow-once")
            end
        )
    end)
end)
