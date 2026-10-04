local assert = require("tests.helpers.assert")

describe("diff_highlighter", function()
    local DiffHighlighter = require("agentic.utils.diff_highlighter")

    describe("find_inline_change", function()
        --- @param old string
        --- @param new string
        --- @param expected { old_start: integer, old_end: integer, new_start: integer, new_end: integer }|nil
        local function assert_change(old, new, expected)
            local result = DiffHighlighter.find_inline_change(old, new)
            if expected == nil then
                assert.is_nil(result)
            else
                assert.same(expected, result)
            end
        end

        it("returns nil for identical lines", function()
            assert_change("hello", "hello", nil)
        end)

        it("detects change at start", function()
            assert_change("hello world", "bye world", {
                old_start = 0,
                old_end = 5,
                new_start = 0,
                new_end = 3,
            })
        end)

        it("detects change at middle", function()
            assert_change("hello beautiful world", "hello ugly world", {
                old_start = 6,
                old_end = 15,
                new_start = 6,
                new_end = 10,
            })
        end)

        it("detects change at end", function()
            assert_change("hello world", "hello there", {
                old_start = 6,
                old_end = 11,
                new_start = 6,
                new_end = 11,
            })
        end)

        it("handles full line replacement", function()
            assert_change("abc", "xyz", {
                old_start = 0,
                old_end = 3,
                new_start = 0,
                new_end = 3,
            })
        end)

        it("handles insertion", function()
            assert_change("hello world", "hello big world", {
                old_start = 6,
                old_end = 6,
                new_start = 6,
                new_end = 10,
            })
        end)

        it("handles deletion", function()
            assert_change("hello big world", "hello world", {
                old_start = 6,
                old_end = 10,
                new_start = 6,
                new_end = 6,
            })
        end)

        it("handles addition to empty line", function()
            assert_change("", "hello", {
                old_start = 0,
                old_end = 0,
                new_start = 0,
                new_end = 5,
            })
        end)

        it("handles deletion to empty line", function()
            assert_change("hello", "", {
                old_start = 0,
                old_end = 5,
                new_start = 0,
                new_end = 0,
            })
        end)

        it("handles UTF-8 characters", function()
            local result = DiffHighlighter.find_inline_change(
                "hello 世界",
                "hello 你好"
            )
            assert.is_not_nil(result)
            if result then
                assert.equal(6, result.old_start)
            end
        end)
    end)

    describe("apply_new_line_word_highlights", function()
        local Theme = require("agentic.theme")
        local ns = vim.api.nvim_create_namespace("test_diff_hl")
        --- @type integer
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end)

        --- @param hl_group string
        --- @return table|nil mark { start_col, details }
        local function find_mark(hl_group)
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            for _, mark in ipairs(marks) do
                local details = mark[4] --- @type table
                if details.hl_group == hl_group then
                    return { start_col = mark[3], details = details }
                end
            end
            return nil
        end

        it(
            "changed line gets line-level DIFF_ADD background under the word overlay",
            function()
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "local x = 2" }
                )

                DiffHighlighter.apply_new_line_word_highlights(
                    bufnr,
                    ns,
                    0,
                    "local x = 1",
                    "local x = 2"
                )

                local line_mark = find_mark(Theme.HL_GROUPS.DIFF_ADD)
                assert.is_not_nil(line_mark)
                if line_mark then
                    assert.equal(0, line_mark.start_col)
                end

                local word_mark = find_mark(Theme.HL_GROUPS.DIFF_ADD_WORD)
                assert.is_not_nil(word_mark)
            end
        )
    end)
end)
