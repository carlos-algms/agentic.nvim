local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local StatusAnimation = require("agentic.ui.status_animation")

describe("agentic.ui.StatusAnimation", function()
    local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

    local bufnr
    local animation
    local base_tabs

    before_each(function()
        base_tabs = #vim.api.nvim_list_tabpages()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
        animation = StatusAnimation:new(bufnr)
    end)

    after_each(function()
        animation:stop()
        animation = nil

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

    --- @return table extmarks
    local function extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            NS_ANIMATION,
            0,
            -1,
            { details = true }
        )
    end

    --- Animation row of the rendered extmark, nil when nothing is drawn.
    --- @return table|nil chunks
    local function animation_chunks()
        local marks = extmarks()
        if #marks == 0 then
            return nil
        end
        local virt_lines = marks[1][4].virt_lines
        return virt_lines and virt_lines[2]
    end

    describe("frame scheduling", function()
        --- @type TestStub
        local defer_stub
        local scheduled

        before_each(function()
            scheduled = {}
            defer_stub = spy.stub(vim, "defer_fn")
            defer_stub:invokes(function(callback)
                scheduled[#scheduled + 1] = callback
                return nil
            end)
        end)

        after_each(function()
            defer_stub:revert()
        end)

        it("drops a stale frame instead of scheduling a successor", function()
            animation:start("generating")
            assert.equal(1, #scheduled)

            local stale_frame = scheduled[1]

            -- `stop` inside `start` cannot un-queue an already-fired timer, so
            -- this callback still runs. Without the epoch it passes the `_state`
            -- check and starts a second chain at double the frame rate.
            animation:start("generating")
            assert.equal(2, #scheduled)

            stale_frame()

            assert.equal(2, #scheduled)
        end)

        it("leaves exactly one live chain after two starts", function()
            animation:start("generating")
            animation:start("thinking")

            local stale_frame = scheduled[1]
            local live_frame = scheduled[2]

            stale_frame()
            assert.equal(2, #scheduled)

            live_frame()
            assert.equal(3, #scheduled)
        end)

        it("stops rescheduling once stopped", function()
            animation:start("generating")
            local frame = scheduled[1]

            animation:stop()
            frame()

            assert.equal(1, #scheduled)
        end)
    end)

    describe("rendering", function()
        it("clears the extmark and the state on stop", function()
            animation:start("generating")
            assert.equal(1, #extmarks())

            animation:stop()

            assert.equal(0, #extmarks())
            assert.is_nil(animation._state)
        end)

        it(
            "renders for a buffer whose only window is in another tab",
            function()
                vim.cmd("tabnew")
                vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
                vim.cmd("tabprevious")

                animation:start("generating")

                local chunks = animation_chunks()
                assert.is_not_nil(chunks)
                ---@cast chunks table
                -- Padding + spinner text: window measured despite living in
                -- another tabpage.
                assert.equal(2, #chunks)
            end
        )

        it("renders without padding when no window shows the buffer", function()
            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)
            assert.is_true(chunks[1][1]:find("generating") ~= nil)
        end)

        it("ignores a hidden float when measuring padding", function()
            local winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 40,
                height = 3,
                focusable = false,
                hide = true,
            })

            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)

            pcall(vim.api.nvim_win_close, winid, true)
        end)
    end)
end)
