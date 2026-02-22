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
        it("moves buttons to buffer bottom when new content arrives", function()
            local callback_spy = spy.new(function() end)
            pm:add_request(
                make_request("tc-1"),
                callback_spy --[[@as function]]
            )

            -- Permission buttons should be at the bottom
            local line_count_before = vim.api.nvim_buf_line_count(bufnr)

            -- Simulate new content arriving after permission prompt
            -- by writing directly (bypassing MessageWriter to avoid triggering callback)
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
                "new tool call output line 1",
                "new tool call output line 2",
            })
            vim.bo[bufnr].modifiable = false

            -- Manually trigger content changed (simulates what MessageWriter does)
            writer:_notify_content_changed()

            -- After reanchor, buttons should be at the new bottom
            local line_count_after = vim.api.nvim_buf_line_count(bufnr)
            assert.is_true(line_count_after > line_count_before)

            -- The last non-empty line should be part of the permission buttons
            local last_lines = vim.api.nvim_buf_get_lines(bufnr, -3, -1, false)
            local found_permission = false
            for _, line in ipairs(last_lines) do
                if line:find("Allow once") or line:find("--- ---") then
                    found_permission = true
                    break
                end
            end
            assert.is_true(found_permission)
        end)

        it("does not trigger recursive on_content_changed", function()
            local notify_spy = spy.on(writer, "_notify_content_changed")

            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            -- Reset counter after initial add_request
            notify_spy:reset()

            -- Trigger reanchor
            writer:_notify_content_changed()

            -- _notify_content_changed was called once (by us), not recursively
            -- by the reanchor itself (which removes+appends buffer lines)
            assert.equal(1, notify_spy.call_count)

            notify_spy:revert()
        end)

        it("keymaps work after reanchor", function()
            local callback_spy = spy.new(function() end)
            pm:add_request(
                make_request("tc-3"),
                callback_spy --[[@as function]]
            )

            -- Trigger reanchor
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(
                bufnr,
                -1,
                -1,
                false,
                { "extra content" }
            )
            vim.bo[bufnr].modifiable = false
            writer:_notify_content_changed()

            -- Verify keymaps still exist after reanchor
            local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
            local found_1 = false
            local found_2 = false
            for _, km in ipairs(keymaps) do
                if km.lhs == "1" then
                    found_1 = true
                end
                if km.lhs == "2" then
                    found_2 = true
                end
            end
            assert.is_true(found_1)
            assert.is_true(found_2)
        end)
    end)

    describe("callback lifecycle", function()
        it(
            "completing a request clears the content changed callback",
            function()
                local callback_spy = spy.new(function() end)
                pm:add_request(
                    make_request("tc-4"),
                    callback_spy --[[@as function]]
                )

                -- Complete the request
                pm:_complete_request("allow-once")

                -- Callback should be cleared
                assert.is_nil(writer._on_content_changed)
            end
        )

        it("clear() clears the content changed callback", function()
            pm:add_request(
                make_request("tc-5"),
                spy.new(function() end) --[[@as function]]
            )

            pm:clear()

            assert.is_nil(writer._on_content_changed)
        end)
    end)
end)
