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
        -- Current tabpage matches the owned one unless a test overrides it.
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
    local function make_coordinator(blocks)
        local widget = {
            find_first_non_widget_window = function()
                return 1
            end,
            open_editor_window = function()
                return 1
            end,
        }
        local message_writer = { tool_call_blocks = blocks }
        return DiffCoordinator:new(
            widget --[[@as any]],
            message_writer --[[@as any]],
            function()
                return OWNED_TAB
            end
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

        it(
            "does nothing when the current tabpage is not the owned one",
            function()
                tabpage_stub:returns(OWNED_TAB + 1)
                local c = make_coordinator({ t1 = edit_block() })

                c:show("t1")

                assert.spy(show_diff_stub).was.called(0)
            end
        )

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
