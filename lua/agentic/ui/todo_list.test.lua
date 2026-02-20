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
                assert.is_true(vim.b[bufnr].agentic_todo_has_items)
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
            assert.is_false(vim.b[bufnr].agentic_todo_has_items)
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
            assert.is_false(vim.b[bufnr].agentic_todo_has_items)
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
            assert.is_false(vim.b[bufnr].agentic_todo_has_items)
        end)
    end)
end)
