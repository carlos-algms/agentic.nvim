local assert = require("tests.helpers.assert")

describe("diff_highlighter", function()
    local DiffHighlighter = require("agentic.utils.diff_highlighter")
    local Theme = require("agentic.theme")

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

    describe("line-level background", function()
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

        --- @param line string
        local function set_single_line(line)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
        end

        --- @param hl_group string
        --- @return table|nil details
        local function find_line_mark(hl_group)
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            for _, mark in ipairs(marks) do
                local details = mark[4] --- @type table
                if details.hl_group == hl_group and details.hl_eol then
                    return details
                end
            end
            return nil
        end

        it("added line carries full-width DIFF_ADD background", function()
            set_single_line("local x = 1")
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                ns,
                0,
                nil,
                "local x = 1"
            )
            assert.is_not_nil(find_line_mark(Theme.HL_GROUPS.DIFF_ADD))
        end)

        it("deleted line carries full-width DIFF_DELETE background", function()
            set_single_line("local x = 1")
            DiffHighlighter.apply_diff_highlights(
                bufnr,
                ns,
                0,
                "local x = 1",
                nil
            )
            assert.is_not_nil(find_line_mark(Theme.HL_GROUPS.DIFF_DELETE))
        end)

        it(
            "modified old line carries full-width DIFF_DELETE background",
            function()
                set_single_line("local x = 1")
                DiffHighlighter.apply_diff_highlights(
                    bufnr,
                    ns,
                    0,
                    "local x = 1",
                    "local x = 2"
                )
                assert.is_not_nil(find_line_mark(Theme.HL_GROUPS.DIFF_DELETE))
            end
        )

        it(
            "modified new line carries full-width DIFF_ADD background under the word highlight",
            function()
                set_single_line("local x = 2")
                DiffHighlighter.apply_new_line_word_highlights(
                    bufnr,
                    ns,
                    0,
                    "local x = 1",
                    "local x = 2"
                )
                assert.is_not_nil(find_line_mark(Theme.HL_GROUPS.DIFF_ADD))
            end
        )

        it("line background renders below the word overlay priority", function()
            set_single_line("local x = 2")
            DiffHighlighter.apply_new_line_word_highlights(
                bufnr,
                ns,
                0,
                "local x = 1",
                "local x = 2"
            )
            local line_mark = find_line_mark(Theme.HL_GROUPS.DIFF_ADD)
            assert.is_not_nil(line_mark)
            if line_mark then
                assert.is_true(
                    line_mark.priority < vim.highlight.priorities.user
                )
            end
        end)

        it(
            "does not error when diff line is longer than the buffer line",
            function()
                -- Fuzzy whitespace matching can pass a diff line longer than the
                -- real buffer line; the extmark end_col must stay in range.
                set_single_line("localx=1")
                assert.has_no_errors(function()
                    DiffHighlighter.apply_diff_highlights(
                        bufnr,
                        ns,
                        0,
                        "local x = 1",
                        nil
                    )
                end)
            end
        )
    end)
end)
