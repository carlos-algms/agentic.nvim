local TextMatcher = require("agentic.utils.text_matcher")
local assert = require("tests.helpers.assert")

describe("TextMatcher", function()
    describe("find_all_prefix_boundary_matches", function()
        it(
            "should match when last target line is prefix of file line",
            function()
                local file_lines = {
                    "  vi.mocked(generateText).mockResolvedValue(mockResult('corporate text'));",
                    "",
                    "  const { executeWithPool } = await import('./pool.ts');",
                    "  const result = await executeWithPool(pool, { input: 'test' }, 'system');",
                }

                local target_lines = {
                    "  vi.mocked(generateText).mockResolvedValue(mockResult('corporate text'));",
                    "",
                    "  const { executeWithPool } = await import('./pool.ts');",
                    "  const result",
                }

                local matches = TextMatcher.find_all_prefix_boundary_matches(
                    file_lines,
                    target_lines
                )

                assert.equal(1, #matches)
                assert.equal(1, matches[1].start_line)
                assert.equal(4, matches[1].end_line)
                assert.equal(
                    " = await executeWithPool(pool, { input: 'test' }, 'system');",
                    matches[1].suffix
                )
            end
        )

        it("should return empty for single-line target", function()
            local file_lines = { "const result = 1;" }
            local target_lines = { "const result" }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)

        it("should return empty when no prefix match on last line", function()
            local file_lines = {
                "line one",
                "line two",
                "line three completely different",
            }

            local target_lines = {
                "line one",
                "line two",
                "no match here",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)

        it("should find multiple prefix matches", function()
            local file_lines = {
                "function a()",
                "  return 1 + extra",
                "end",
                "function a()",
                "  return 1 + extra",
                "end",
            }

            local target_lines = {
                "function a()",
                "  return 1",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(2, #matches)
            assert.equal(1, matches[1].start_line)
            assert.equal(" + extra", matches[1].suffix)
            assert.equal(4, matches[2].start_line)
            assert.equal(" + extra", matches[2].suffix)
        end)

        it(
            "should match with whitespace-trimmed strategy when exact fails",
            function()
                local file_lines = {
                    "line one  ",
                    "line two = full content;",
                }

                local target_lines = {
                    "line one",
                    "line two",
                }

                local matches = TextMatcher.find_all_prefix_boundary_matches(
                    file_lines,
                    target_lines
                )

                assert.equal(1, #matches)
                assert.equal(" = full content;", matches[1].suffix)
            end
        )

        it("should not match when head lines differ", function()
            local file_lines = {
                "different line",
                "const result = await foo();",
            }

            local target_lines = {
                "line one",
                "const result",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)
    end)
end)
