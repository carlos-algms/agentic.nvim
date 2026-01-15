local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("tool_call_diff", function()
    --- @type agentic.ui.ToolCallDiff
    local ToolCallDiff
    --- @type agentic.utils.FileSystem
    local FileSystem

    local read_stub
    local path_stub

    before_each(function()
        FileSystem = require("agentic.utils.file_system")
        ToolCallDiff = require("agentic.ui.tool_call_diff")

        read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
        path_stub = spy.stub(FileSystem, "to_absolute_path")
        path_stub:invokes(function(path)
            return path
        end)
    end)

    after_each(function()
        read_stub:revert()
        path_stub:revert()
    end)

    describe("extract_diff_blocks", function()
        it("creates new file block when old_text is nil-like", function()
            read_stub:returns(nil)

            local blocks_nil = ToolCallDiff.extract_diff_blocks({
                path = "/new_file.lua",
                old_text = nil,
                new_text = "line1\nline2\nline3",
            })

            assert.equal(1, #blocks_nil)
            assert.equal(1, blocks_nil[1].start_line)
            assert.equal(0, blocks_nil[1].end_line) -- Pure insertion
            assert.equal(0, #blocks_nil[1].old_lines)
            assert.equal(3, #blocks_nil[1].new_lines)

            local blocks_vim_nil = ToolCallDiff.extract_diff_blocks({
                path = "/new_file.lua",
                old_text = vim.NIL,
                new_text = "new content",
            })

            assert.equal(1, #blocks_vim_nil)
            assert.equal(0, #blocks_vim_nil[1].old_lines)
        end)

        it(
            "treats nil old_text as full file replacement when file exists",
            function()
                local file_content = {
                    "import { useQueryClient } from '@tanstack/react-query';",
                    "",
                    "import { useAuthState } from '@org/auth/react';",
                }
                read_stub:returns(file_content)

                local new_content = table.concat({
                    "import type { QueryClient } from '@tanstack/react-query';",
                    "import { useQueryClient } from '@tanstack/react-query';",
                    "",
                    "import { useAuthState } from '@org/auth/react';",
                }, "\n")

                local blocks = ToolCallDiff.extract_diff_blocks({
                    path = "/test.tsx",
                    old_text = nil,
                    new_text = new_content,
                })

                assert.is_true(#blocks > 0)
                assert.equal(1, blocks[1].start_line)
            end
        )

        it("handles single line modification via substring match", function()
            local file_lines = {
                "const x = 1;",
                "const y = 2;",
                "const z = 3;",
            }
            read_stub:returns(file_lines)

            local blocks = ToolCallDiff.extract_diff_blocks({
                path = "/test.js",
                old_text = "const y = 2;",
                new_text = "const y = 42;",
            })

            assert.equal(1, #blocks)
            assert.equal(2, blocks[1].start_line)
            assert.equal(2, blocks[1].end_line)
            assert.same({ "const y = 2;" }, blocks[1].old_lines)
            assert.same({ "const y = 42;" }, blocks[1].new_lines)
        end)

        it("finds all occurrences when replace_all is true", function()
            local file_lines = {
                "console.log('hello');",
                "console.log('world');",
                "console.log('hello');",
            }
            read_stub:returns(file_lines)

            local blocks = ToolCallDiff.extract_diff_blocks({
                path = "/test.js",
                old_text = "console.log('hello');",
                new_text = "console.log('goodbye');",
                replace_all = true,
            })

            assert.equal(2, #blocks)
            assert.equal(1, blocks[1].start_line)
            assert.equal(3, blocks[2].start_line)
        end)
    end)

    describe("filter_unchanged_lines", function()
        it("filters unchanged lines and preserves indices", function()
            local old_lines = {
                "line1", -- unchanged
                "old2", -- changed (idx 2)
                "line3", -- unchanged
                "line4", -- unchanged
                "old5", -- changed (idx 5)
            }
            local new_lines = {
                "line1",
                "new2",
                "line3",
                "line4",
                "new5",
            }

            local filtered =
                ToolCallDiff.filter_unchanged_lines(old_lines, new_lines)

            assert.same({ "old2", "old5" }, filtered.old_lines)
            assert.same({ "new2", "new5" }, filtered.new_lines)
            assert.equal(2, #filtered.pairs)

            -- Verify original indices preserved for position calculation
            assert.equal(2, filtered.pairs[1].old_idx)
            assert.equal(5, filtered.pairs[2].old_idx)
        end)

        it("handles pure insertions (empty old)", function()
            local filtered = ToolCallDiff.filter_unchanged_lines(
                {},
                { "new1", "new2" }
            )

            assert.equal(0, #filtered.old_lines)
            assert.same({ "new1", "new2" }, filtered.new_lines)
            assert.equal(2, #filtered.pairs)
            assert.is_nil(filtered.pairs[1].old_line)
        end)

        it("handles pure deletions (empty new)", function()
            local filtered = ToolCallDiff.filter_unchanged_lines(
                { "old1", "old2" },
                {}
            )

            assert.same({ "old1", "old2" }, filtered.old_lines)
            assert.equal(0, #filtered.new_lines)
            assert.equal(2, #filtered.pairs)
            assert.is_nil(filtered.pairs[1].new_line)
        end)

        it("returns empty when all lines unchanged", function()
            local filtered = ToolCallDiff.filter_unchanged_lines(
                { "line1", "line2" },
                { "line1", "line2" }
            )

            assert.equal(0, #filtered.old_lines)
            assert.equal(0, #filtered.new_lines)
            assert.equal(0, #filtered.pairs)
        end)

        it("handles insertion with unchanged context line", function()
            local filtered = ToolCallDiff.filter_unchanged_lines(
                { "ignore-scripts=false" },
                { "ignore-scripts=false", "test=true" }
            )

            assert.equal(0, #filtered.old_lines)
            assert.same({ "test=true" }, filtered.new_lines)
            assert.equal(1, #filtered.pairs)
            assert.is_nil(filtered.pairs[1].old_line)
            assert.equal("test=true", filtered.pairs[1].new_line)
        end)
    end)

    describe("minimize_diff_blocks", function()
        it("handles single-line blocks (unchanged vs changed)", function()
            local unchanged_block = {
                {
                    start_line = 1,
                    end_line = 1,
                    old_lines = { "same" },
                    new_lines = { "same" },
                },
            }
            local changed_block = {
                {
                    start_line = 1,
                    end_line = 1,
                    old_lines = { "old" },
                    new_lines = { "new" },
                },
            }

            assert.equal(0, #ToolCallDiff.minimize_diff_blocks(unchanged_block))

            local minimized = ToolCallDiff.minimize_diff_blocks(changed_block)
            assert.equal(1, #minimized)
            assert.same({ "old" }, minimized[1].old_lines)
            assert.same({ "new" }, minimized[1].new_lines)
        end)

        it("filters entirely unchanged multi-line blocks", function()
            local diff_blocks = {
                {
                    start_line = 1,
                    end_line = 3,
                    old_lines = { "a", "b", "c" },
                    new_lines = { "a", "b", "c" },
                },
            }

            assert.equal(0, #ToolCallDiff.minimize_diff_blocks(diff_blocks))
        end)

        it("keeps insertion with unchanged context", function()
            local diff_blocks = {
                {
                    start_line = 5,
                    end_line = 5,
                    old_lines = { "ignore-scripts=false" },
                    new_lines = { "ignore-scripts=false", "test=true" },
                },
            }

            local minimized = ToolCallDiff.minimize_diff_blocks(diff_blocks)

            -- vim.diff creates one hunk with old_line and both new_lines
            assert.equal(1, #minimized)
            assert.same({ "ignore-scripts=false" }, minimized[1].old_lines)
            assert.same(
                { "ignore-scripts=false", "test=true" },
                minimized[1].new_lines
            )
        end)

        it("extracts only changed lines from multi-line block", function()
            local diff_blocks = {
                {
                    start_line = 1,
                    end_line = 4,
                    old_lines = { "a", "old2", "c", "old4" },
                    new_lines = { "a", "new2", "c", "new4" },
                },
            }

            local minimized = ToolCallDiff.minimize_diff_blocks(diff_blocks)

            -- Should create separate hunks for each change
            assert.equal(2, #minimized)
            assert.same({ "old2" }, minimized[1].old_lines)
            assert.same({ "new2" }, minimized[1].new_lines)
            assert.same({ "old4" }, minimized[2].old_lines)
            assert.same({ "new4" }, minimized[2].new_lines)
        end)

        it("handles pure insertion", function()
            local diff_blocks = {
                {
                    start_line = 2,
                    end_line = 2,
                    old_lines = {},
                    new_lines = { "new line" },
                },
            }

            local minimized = ToolCallDiff.minimize_diff_blocks(diff_blocks)

            assert.equal(1, #minimized)
            assert.equal(0, #minimized[1].old_lines)
            assert.same({ "new line" }, minimized[1].new_lines)
        end)

        it("handles pure deletion", function()
            local diff_blocks = {
                {
                    start_line = 1,
                    end_line = 1,
                    old_lines = { "deleted" },
                    new_lines = {},
                },
            }

            local minimized = ToolCallDiff.minimize_diff_blocks(diff_blocks)

            assert.equal(1, #minimized)
            assert.same({ "deleted" }, minimized[1].old_lines)
            assert.equal(0, #minimized[1].new_lines)
        end)
    end)
end)
