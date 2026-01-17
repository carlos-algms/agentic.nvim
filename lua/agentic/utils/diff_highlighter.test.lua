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
end)
