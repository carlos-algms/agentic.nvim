local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

--- @param content string
--- @param status string
--- @return agentic.acp.PlanEntry
local function entry(content, status)
    --- @type agentic.acp.PlanEntry
    local e = { content = content, status = status, priority = "medium" }
    return e
end

describe("agentic.ui.TodoList", function()
    local TodoList = require("agentic.ui.todo_list")

    --- @type integer
    local bufnr
    --- @type TestStub
    local render_header_stub
    --- @type TestSpy
    local on_change_spy
    --- @type TestSpy
    local on_close_spy

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)
        on_close_spy = spy.new(function() end)

        local WindowDecoration = require("agentic.ui.window_decoration")
        render_header_stub = spy.stub(WindowDecoration, "render_header")
    end)

    after_each(function()
        render_header_stub:revert()

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("render", function()
        it(
            "writes checkbox lines, updates header, and notifies on_change",
            function()
                local todo_list = TodoList:new(
                    bufnr,
                    on_change_spy --[[@as function]],
                    on_close_spy --[[@as function]]
                )

                todo_list:render({
                    entry("First task", "pending"),
                    entry("Second task", "completed"),
                    entry("Third task", "in_progress"),
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal(3, #lines)
                assert.equal("- [ ] First task", lines[1])
                assert.equal("- [x] Second task", lines[2])
                assert.equal("- [~] Third task", lines[3])

                assert.stub(render_header_stub).was.called(1)
                local call_args = render_header_stub.calls[1]
                assert.equal(bufnr, call_args[1])
                assert.equal("todos", call_args[2])
                assert.equal("1 of 3", call_args[3])

                assert.spy(on_change_spy).was.called(1)
                assert.is_false(todo_list:is_empty())
            end
        )

        it("clears buffer and skips header for empty entries", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:render({})

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("", lines[1])
            assert.stub(render_header_stub).was.called(0)
            assert.spy(on_change_spy).was.called(1)
            assert.is_true(todo_list:is_empty())
        end)

        it("replaces previous content on re-render", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:render({ entry("Old task", "pending") })
            todo_list:render({ entry("New task", "completed") })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("- [x] New task", lines[1])

            assert.stub(render_header_stub).was.called(2)
            assert.equal("1 of 1", render_header_stub.calls[2][3])
        end)
    end)

    describe("close_if_all_completed", function()
        it("does nothing when not all tasks are completed", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:close_if_all_completed()
            assert.spy(on_close_spy).was.called(0)

            todo_list:render({
                entry("Done", "completed"),
                entry("Working", "in_progress"),
            })

            todo_list:close_if_all_completed()
            assert.spy(on_close_spy).was.called(0)
            assert.equal(2, todo_list.total_count)
        end)

        it("clears and calls on_close when all tasks completed", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:render({
                entry("Done", "completed"),
                entry("Also done", "completed"),
            })

            todo_list:close_if_all_completed()

            assert.spy(on_close_spy).was.called(1)
            assert.is_true(todo_list:is_empty())
        end)
    end)

    describe("_scroll_to_non_completed", function()
        --- @type integer|nil
        local winid

        after_each(function()
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
                winid = nil
            end
        end)

        --- @param height integer
        --- @return integer
        local function open_todo_window(height)
            winid = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                height = height,
            })
            assert.equal(height, vim.api.nvim_win_get_height(winid))
            return winid
        end

        --- @return integer
        local function get_topline()
            ---@cast winid integer
            return vim.api.nvim_win_call(winid, function()
                return vim.fn.winsaveview().topline
            end)
        end

        it("does not scroll when non-completed items are visible", function()
            open_todo_window(5)
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:render({
                entry("Done", "completed"),
                entry("Task A", "pending"),
                entry("Task B", "pending"),
            })

            assert.equal(1, get_topline())
        end)

        it("scrolls to show at least 2 non-completed items", function()
            open_todo_window(4)
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            local entries = {}
            for i = 1, 7 do
                table.insert(entries, entry("Done " .. i, "completed"))
            end
            table.insert(entries, entry("Task A", "pending"))
            table.insert(entries, entry("Task B", "in_progress"))
            table.insert(entries, entry("Task C", "pending"))

            todo_list:render(entries)

            -- first_non_completed=8, target=8-(4-2)=6, max_top=10-4+1=7
            assert.equal(6, get_topline())
        end)

        it("clamps topline so last todo is last visible line", function()
            open_todo_window(4)
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            local entries = {}
            for i = 1, 9 do
                table.insert(entries, entry("Done " .. i, "completed"))
            end
            table.insert(entries, entry("Last task", "pending"))

            todo_list:render(entries)

            -- first_non_completed=10, target=10-(4-2)=8, max_top=10-4+1=7
            assert.equal(7, get_topline())
        end)

        it("does not error when no window is open", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            assert.has_no_errors(function()
                todo_list:render({
                    entry("Done", "completed"),
                    entry("Done 2", "completed"),
                    entry("Done 3", "completed"),
                    entry("Done 4", "completed"),
                    entry("Done 5", "completed"),
                    entry("Task", "pending"),
                })
            end)
        end)

        it("does not scroll when window is taller than content", function()
            -- Simulates real-world scenario: window has padding (height > entries)
            -- e.g., 8 entries in a window of height 10 (due to dynamic height + padding)
            open_todo_window(10)
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            local entries = {}
            for i = 1, 6 do
                table.insert(entries, entry("Done " .. i, "completed"))
            end
            table.insert(entries, entry("Task A", "in_progress"))
            table.insert(entries, entry("Task B", "pending"))

            todo_list:render(entries)

            -- total=8 <= win_height=10, all content fits, no scroll
            assert.equal(1, get_topline())
        end)

        it("accounts for winbar reducing visible lines", function()
            open_todo_window(5)
            ---@cast winid integer
            vim.wo[winid].winbar = "test winbar"

            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            local entries = {}
            for i = 1, 7 do
                table.insert(entries, entry("Done " .. i, "completed"))
            end
            table.insert(entries, entry("Task A", "pending"))
            table.insert(entries, entry("Task B", "in_progress"))
            table.insert(entries, entry("Task C", "pending"))

            todo_list:render(entries)

            -- win_height=5, winbar=1, effective=4
            -- first_non_completed=8, target=8-(4-2)=6, max_top=10-4+1=7
            assert.equal(6, get_topline())
        end)

        it(
            "scrolls first non-completed into view with effective height 1",
            function()
                open_todo_window(2)
                ---@cast winid integer
                vim.wo[winid].winbar = "test winbar"

                local todo_list = TodoList:new(
                    bufnr,
                    on_change_spy --[[@as function]],
                    on_close_spy --[[@as function]]
                )

                local entries = {}
                for i = 1, 5 do
                    table.insert(entries, entry("Done " .. i, "completed"))
                end
                table.insert(entries, entry("Task A", "pending"))
                table.insert(entries, entry("Task B", "in_progress"))

                todo_list:render(entries)

                -- win_height=2, winbar=1, effective=1
                -- first_non_completed=6, visible_lines=min(1,7)=1
                -- target=6-max(0,1-2)=6-0=6, max_top=7-1+1=7
                -- topline=6, first non-completed is visible
                -- topline=6 means first non-completed item is visible
                assert.equal(6, get_topline())
            end
        )

        it("does not scroll when all items are completed", function()
            open_todo_window(3)
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            local entries = {}
            for i = 1, 6 do
                table.insert(entries, entry("Done " .. i, "completed"))
            end

            todo_list:render(entries)

            assert.equal(1, get_topline())
        end)
    end)

    describe("clear", function()
        it("resets state and clears buffer", function()
            local todo_list = TodoList:new(
                bufnr,
                on_change_spy --[[@as function]],
                on_close_spy --[[@as function]]
            )

            todo_list:render({
                entry("A", "completed"),
                entry("B", "pending"),
            })

            todo_list:clear()

            assert.is_true(todo_list:is_empty())
            assert.equal(0, todo_list.completed_count)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("", lines[1])
        end)
    end)
end)
