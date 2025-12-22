describe("agentic.ui.CodeSelection", function()
    local CodeSelection = require("agentic.ui.code_selection")
    local spy = require("luassert.spy")

    --- @type integer
    local bufnr
    --- @type agentic.ui.CodeSelection
    local code_selection
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
end)
