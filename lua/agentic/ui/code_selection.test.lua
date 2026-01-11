local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.CodeSelection", function()
    local CodeSelection = require("agentic.ui.code_selection")

    --- @type integer
    local bufnr
    --- @type agentic.ui.CodeSelection
    local code_selection
    --- @type TestSpy
    local on_change_spy

    --- Helper to create a simple test selection
    --- @return agentic.Selection
    local function create_simple_selection()
        return {
            lines = { "test" },
            start_line = 1,
            end_line = 1,
            file_path = "test.lua",
            file_type = "lua",
        }
    end

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)
        code_selection =
            CodeSelection:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("add and get_selections", function()
        it("adds selection and retrieves it", function()
            --- @type agentic.Selection
            local selection = {
                lines = { "local function test()", "  return 42", "end" },
                start_line = 10,
                end_line = 12,
                file_path = "test.lua",
                file_type = "lua",
            }

            code_selection:add(selection)

            local selections = code_selection:get_selections()

            assert.equal(1, #selections)
            assert.same(selection.lines, selections[1].lines)
            assert.equal(10, selections[1].start_line)
            assert.equal(12, selections[1].end_line)
            assert.equal("test.lua", selections[1].file_path)
            assert.equal("lua", selections[1].file_type)
            assert.spy(on_change_spy).was.called(1)
        end)

        it("adds multiple selections", function()
            --- @type agentic.Selection
            local selection1 = {
                lines = { "function a()" },
                start_line = 1,
                end_line = 1,
                file_path = "a.lua",
                file_type = "lua",
            }

            --- @type agentic.Selection
            local selection2 = {
                lines = { "function b()" },
                start_line = 5,
                end_line = 5,
                file_path = "b.lua",
                file_type = "lua",
            }

            code_selection:add(selection1)
            code_selection:add(selection2)

            local selections = code_selection:get_selections()

            assert.equal(2, #selections)
            assert.same(selection1.lines, selections[1].lines)
            assert.same(selection2.lines, selections[2].lines)
            assert.spy(on_change_spy).was.called(2)
        end)

        it("does not add selection with empty lines", function()
            --- @type agentic.Selection
            local empty_selection = {
                lines = {},
                start_line = 1,
                end_line = 1,
                file_path = "test.lua",
                file_type = "lua",
            }

            code_selection:add(empty_selection)

            local selections = code_selection:get_selections()

            assert.equal(0, #selections)
            assert.spy(on_change_spy).was.called(0)
        end)

        it("returns deep copy of selections", function()
            local selection = create_simple_selection()

            code_selection:add(selection)

            local selections1 = code_selection:get_selections()
            local selections2 = code_selection:get_selections()

            selections1[1].lines[1] = "modified"

            assert.equal("test", selections2[1].lines[1])
        end)
    end)

    describe("is_empty", function()
        it("returns true when no selections added", function()
            assert.is_true(code_selection:is_empty())
        end)

        it("returns false when selections exist", function()
            local selection = create_simple_selection()

            code_selection:add(selection)

            assert.is_false(code_selection:is_empty())
        end)
    end)

    describe("clear", function()
        it("removes all selections", function()
            local selection = create_simple_selection()

            code_selection:add(selection)
            assert.is_false(code_selection:is_empty())

            code_selection:clear()

            assert.is_true(code_selection:is_empty())
            assert.spy(on_change_spy).was.called(2)
        end)

        it("clears buffer content", function()
            local selection = create_simple_selection()

            code_selection:add(selection)

            local line_count = vim.api.nvim_buf_line_count(bufnr)
            assert.is_true(line_count > 0)

            code_selection:clear()

            line_count = vim.api.nvim_buf_line_count(bufnr)
            assert.equal(1, line_count)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("", lines[1])
        end)
    end)

    --- Helper to create two distinct test selections
    --- @return agentic.Selection, agentic.Selection
    local function create_two_selections()
        --- @type agentic.Selection
        local selection1 = {
            lines = { "local alpha = 100", "return alpha * 2" },
            start_line = 5,
            end_line = 6,
            file_path = "src/alpha.lua",
            file_type = "lua",
        }

        --- @type agentic.Selection
        local selection2 = {
            lines = { "local beta = 200", "return beta * 3" },
            start_line = 15,
            end_line = 16,
            file_path = "src/beta.lua",
            file_type = "lua",
        }

        return selection1, selection2
    end

    describe("remove_at_cursor with multiple selections", function()
        it(
            "removes second selection when cursor is on last line of second fence block",
            function()
                local selection1, selection2 = create_two_selections()

                code_selection:add(selection1)
                code_selection:add(selection2)

                -- Verify both selections exist with correct file paths
                local selections = code_selection:get_selections()
                assert.equal(2, #selections)
                assert.equal("src/alpha.lua", selections[1].file_path)
                assert.equal("src/beta.lua", selections[2].file_path)

                -- Calculate last line of second selection's fence block
                -- Selection 1: lines 1-4 (opener + 2 content + closer)
                -- Selection 2: lines 5-8 (opener + 2 content + closer)
                -- Last line of second selection = line 8
                local last_line_of_second_fence = 8

                -- Remove at the last line of the second fence
                code_selection:remove_at_cursor(last_line_of_second_fence)

                -- Verify only first selection remains in memory
                selections = code_selection:get_selections()
                assert.equal(1, #selections)
                assert.same(selection1.lines, selections[1].lines)
                assert.equal("src/alpha.lua", selections[1].file_path)
                assert.equal(5, selections[1].start_line)
                assert.equal(6, selections[1].end_line)

                -- Verify buffer only contains first selection's fence block
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal(4, #lines)
                assert.equal("```lua src/alpha.lua#L5-L6", lines[1])
                assert.equal("local alpha = 100", lines[2])
                assert.equal("return alpha * 2", lines[3])
                assert.equal("```", lines[4])

                -- Verify on_change was called 3 times (add, add, remove)
                assert.spy(on_change_spy).was.called(3)
            end
        )

        it(
            "removes first selection when cursor is on the first fence block",
            function()
                local selection1, selection2 = create_two_selections()

                code_selection:add(selection1)
                code_selection:add(selection2)

                local selections = code_selection:get_selections()
                assert.equal(2, #selections)

                code_selection:remove_at_cursor(2)

                -- Verify only second selection remains in memory
                selections = code_selection:get_selections()
                assert.equal(1, #selections)
                assert.same(selection2.lines, selections[1].lines)
                assert.equal("src/beta.lua", selections[1].file_path)
                assert.equal(15, selections[1].start_line)
                assert.equal(16, selections[1].end_line)

                -- Verify buffer only contains second selection's fence block
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal(4, #lines)
                assert.equal("```lua src/beta.lua#L15-L16", lines[1])
                assert.equal("local beta = 200", lines[2])
                assert.equal("return beta * 3", lines[3])
                assert.equal("```", lines[4])

                assert.spy(on_change_spy).was.called(3)
            end
        )
    end)

    describe("remove_range with multiple selections", function()
        it("removes first selection when range covers lines 2-3", function()
            local selection1, selection2 = create_two_selections()

            code_selection:add(selection1)
            code_selection:add(selection2)

            local selections = code_selection:get_selections()
            assert.equal(2, #selections)

            -- Remove range covering lines 2-3 (within first fence)
            code_selection:remove_range(2, 3)

            -- Verify only second selection remains
            selections = code_selection:get_selections()
            assert.equal(1, #selections)
            assert.same(selection2.lines, selections[1].lines)
            assert.equal("src/beta.lua", selections[1].file_path)

            -- Verify buffer only contains second selection
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(4, #lines)
            assert.equal("```lua src/beta.lua#L15-L16", lines[1])

            assert.spy(on_change_spy).was.called(3)
        end)

        it(
            "removes second selection when range covers last two lines",
            function()
                local selection1, selection2 = create_two_selections()

                code_selection:add(selection1)
                code_selection:add(selection2)

                local selections = code_selection:get_selections()
                assert.equal(2, #selections)

                -- Selection 1: lines 1-4, Selection 2: lines 5-8
                -- Remove range covering lines 7-8 (last two lines of second fence)
                code_selection:remove_range(7, 8)

                -- Verify only first selection remains
                selections = code_selection:get_selections()
                assert.equal(1, #selections)
                assert.same(selection1.lines, selections[1].lines)
                assert.equal("src/alpha.lua", selections[1].file_path)

                -- Verify buffer only contains first selection
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal(4, #lines)
                assert.equal("```lua src/alpha.lua#L5-L6", lines[1])

                assert.spy(on_change_spy).was.called(3)
            end
        )

        it("removes both selections when range overlaps both fences", function()
            local selection1, selection2 = create_two_selections()

            code_selection:add(selection1)
            code_selection:add(selection2)

            local selections = code_selection:get_selections()
            assert.equal(2, #selections)

            -- Selection 1: lines 1-4, Selection 2: lines 5-8
            -- Remove range covering lines 3-6 (overlaps both fences)
            code_selection:remove_range(3, 6)

            -- Verify both selections removed
            assert.is_true(code_selection:is_empty())

            -- Verify buffer is empty
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("", lines[1])

            assert.spy(on_change_spy).was.called(3)
        end)
    end)
end)
