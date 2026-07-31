local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiffCoordinator = require("agentic.ui.diff_coordinator")

describe("agentic.ui.DiffCoordinator", function()
    --- @type TestStub
    local show_diff_stub
    --- @type TestStub
    local clear_diff_stub
    --- @type TestStub
    local tabpage_stub
    local saved_enabled

    --- The tabpage the coordinator believes it owns.
    local OWNED_TAB = 7

    before_each(function()
        show_diff_stub = spy.stub(DiffPreview, "show_diff")
        clear_diff_stub = spy.stub(DiffPreview, "clear_diff")
        -- Current tab matches the owned one unless a case overrides it.
        tabpage_stub = spy.stub(vim.api, "nvim_get_current_tabpage")
        tabpage_stub:returns(OWNED_TAB)

        saved_enabled = Config.diff_preview.enabled
        Config.diff_preview.enabled = true
    end)

    after_each(function()
        show_diff_stub:revert()
        clear_diff_stub:revert()
        tabpage_stub:revert()
        Config.diff_preview.enabled = saved_enabled
    end)

    --- Build a coordinator whose message_writer holds the given blocks.
    --- @param blocks table<string, any>
    --- @param hidden boolean|nil When true the widget reports no visible tab
    local function make_coordinator(blocks, hidden)
        local widget = {
            buf_nrs = {},
            find_first_non_widget_window = function()
                return 1
            end,
            open_editor_window = function()
                return 1
            end,
            get_visible_tab_id = function()
                if hidden then
                    return nil
                end
                return OWNED_TAB
            end,
        }
        local message_writer = { tool_call_blocks = blocks }
        return DiffCoordinator:new(
            widget --[[@as any]],
            message_writer --[[@as any]]
        )
    end

    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function edit_block()
        return {
            tool_call_id = "t1",
            kind = "edit",
            file_path = "/tmp/a.lua",
            diff = { changed_pairs = {} },
        } --[[@as any]]
    end

    describe("show", function()
        it("dispatches show_diff for a valid edit tracker", function()
            local c = make_coordinator({ t1 = edit_block() })

            c:show("t1")

            assert.spy(show_diff_stub).was.called(1)
            local opts = show_diff_stub.calls[1][1]
            assert.equal("/tmp/a.lua", opts.file_path)
            assert.equal("function", type(opts.get_winid))
        end)

        it("does nothing when diff_preview is disabled", function()
            Config.diff_preview.enabled = false
            local c = make_coordinator({ t1 = edit_block() })

            c:show("t1")

            assert.spy(show_diff_stub).was.called(0)
        end)

        it("does nothing when the widget is hidden", function()
            local c = make_coordinator({ t1 = edit_block() }, true)

            c:show("t1")

            assert.spy(show_diff_stub).was.called(0)
        end)

        it("renders when the widget is visible in a non-current tab", function()
            -- Defect: the old rule refused unless the widget's tab was current,
            -- so a background session never rendered its diff.
            tabpage_stub:returns(OWNED_TAB + 1)
            local c = make_coordinator({ t1 = edit_block() })

            c:show("t1")

            assert.spy(show_diff_stub).was.called(1)
        end)

        it("passes its own diff state to show_diff", function()
            local c1 = make_coordinator({ t1 = edit_block() })
            local c2 = make_coordinator({ t1 = edit_block() })

            c1:show("t1")
            c2:show("t1")

            local state1 = show_diff_stub.calls[1][1].state
            local state2 = show_diff_stub.calls[2][1].state
            assert.equal("table", type(state1))
            assert.is_true(state1 ~= state2)
        end)

        it("does nothing for a non-edit tracker", function()
            local block = edit_block()
            block.kind = "read"
            local c = make_coordinator({ t1 = block })

            c:show("t1")

            assert.spy(show_diff_stub).was.called(0)
        end)

        it("does nothing when the tracker has no diff", function()
            local block = edit_block()
            block.diff = nil
            local c = make_coordinator({ t1 = block })

            c:show("t1")

            assert.spy(show_diff_stub).was.called(0)
        end)

        it("does nothing for an unknown tool_call_id", function()
            local c = make_coordinator({})

            c:show("missing")

            assert.spy(show_diff_stub).was.called(0)
        end)
    end)

    describe("clear", function()
        it("dispatches clear_diff for a valid edit tracker", function()
            local c = make_coordinator({ t1 = edit_block() })

            c:clear("t1", true)

            assert.spy(clear_diff_stub).was.called(1)
            assert.equal("/tmp/a.lua", clear_diff_stub.calls[1][1])
            assert.equal(true, clear_diff_stub.calls[1][2])
        end)

        it("does nothing for an invalid tracker", function()
            local c = make_coordinator({})

            c:clear("missing", false)

            assert.spy(clear_diff_stub).was.called(0)
        end)
    end)
end)

-- Real widget and real DiffPreview: the stubbed suite above cannot show a diff
-- landing in the session's own tab without moving the cursor.
describe("agentic.ui.DiffCoordinator (real widget)", function()
    local ChatWidget = require("agentic.ui.chat_widget")
    local FileSystem = require("agentic.utils.file_system")
    local HunkNavigation = require("agentic.ui.hunk_navigation")

    local widget
    local coordinator
    local file_path
    local saved_enabled
    local saved_layout
    local base_tabs
    --- @type TestStub
    local schedule_stub

    local FILE_LINES = { "local x = 1", "print(x)", "" }

    before_each(function()
        base_tabs = #vim.api.nvim_list_tabpages()
        saved_enabled = Config.diff_preview.enabled
        saved_layout = Config.diff_preview.layout
        Config.diff_preview.enabled = true
        Config.diff_preview.layout = "inline"

        -- `show_diff` defers the first `navigate_next` via `vim.schedule`. Left
        -- queued it fires during a LATER case, after this one's tab and buffer
        -- are gone. Run inline: nothing escapes, and flushing in-process would
        -- pump mini.test's own queue (`references/async-tests.md`).
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            callback()
        end)

        file_path = vim.fn.tempname() .. ".lua"
        vim.fn.writefile(FILE_LINES, file_path)

        vim.cmd("tabnew")
        widget = ChatWidget:new(spy.new(function() end) --[[@as function]])

        local message_writer = {
            tool_call_blocks = {
                t1 = {
                    tool_call_id = "t1",
                    kind = "edit",
                    file_path = file_path,
                    diff = { old = { "print(x)" }, new = { "print(x + 1)" } },
                },
            },
        }
        coordinator = DiffCoordinator:new(widget, message_writer --[[@as any]])
    end)

    after_each(function()
        schedule_stub:revert()

        pcall(function()
            widget:destroy()
        end)
        widget = nil
        coordinator = nil

        local bufnr = vim.fn.bufnr(FileSystem.to_absolute_path(file_path))
        if bufnr ~= -1 then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        os.remove(file_path)

        while #vim.api.nvim_list_tabpages() > base_tabs do
            local ok = pcall(function()
                vim.cmd("tabclose!")
            end)
            if not ok then
                break
            end
        end

        Config.diff_preview.enabled = saved_enabled
        Config.diff_preview.layout = saved_layout
    end)

    --- @return integer|nil bufnr Buffer the coordinator armed a diff on
    local function armed_bufnr()
        return coordinator.diff_state.preview_bufnr
    end

    it("renders no diff and arms no state for a hidden widget", function()
        coordinator:show("t1")

        assert.is_nil(armed_bufnr())
    end)

    it("renders the diff when the widget is visible in this tab", function()
        widget:show({ focus_prompt = false })

        coordinator:show("t1")

        local bufnr = armed_bufnr()
        assert.is_not_nil(bufnr)
        ---@cast bufnr integer
        local marks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            HunkNavigation.NS_DIFF,
            0,
            -1,
            {}
        )
        assert.is_true(#marks > 0)
    end)

    it("renders into the widget's tab without moving the cursor", function()
        widget:show({ focus_prompt = false })

        vim.cmd("tabnew")
        local other_tab = vim.api.nvim_get_current_tabpage()
        local other_win = vim.api.nvim_get_current_win()

        coordinator:show("t1")

        local bufnr = armed_bufnr()
        assert.is_not_nil(bufnr)
        ---@cast bufnr integer

        -- Q5 invariant: a background session paints its own tab and leaves
        -- the user where they were.
        assert.equal(other_tab, vim.api.nvim_get_current_tabpage())
        assert.equal(other_win, vim.api.nvim_get_current_win())

        for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
            assert.is_not.equal(other_tab, vim.api.nvim_win_get_tabpage(winid))
        end
    end)

    it("clears only the calling coordinator's state", function()
        widget:show({ focus_prompt = false })
        coordinator:show("t1")
        assert.is_not_nil(armed_bufnr())

        local other = DiffCoordinator:new(widget, {
            tool_call_blocks = {},
        } --[[@as any]])
        other.diff_state.preview_bufnr = 999

        coordinator:clear("t1")

        assert.is_nil(armed_bufnr())
        assert.equal(999, other.diff_state.preview_bufnr)
    end)
end)
