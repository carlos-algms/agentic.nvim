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

        -- Stub file system to avoid actual file reads
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
        it(
            "creates new file block when old_text is nil and file does not exist",
            function()
                read_stub:returns(nil)

                local blocks = ToolCallDiff.extract_diff_blocks({
                    path = "/new_file.lua",
                    old_text = nil,
                    new_text = "line1\nline2\nline3",
                })

                assert.equal(1, #blocks)
                assert.equal(1, blocks[1].start_line)
                -- end_line is 0 for pure insertions (no old lines)
                assert.equal(0, blocks[1].end_line)
                assert.equal(0, #blocks[1].old_lines)
                assert.equal(3, #blocks[1].new_lines)
            end
        )

        it(
            "treats nil old_text as full file replacement when file exists",
            function()
                local file_content = {
                    "import { useQueryClient } from '@tanstack/react-query';",
                    "",
                    "import { useAuthState } from '@org/auth/react';",
                    "import { useRouterAdapter } from '@org/routing';",
                    "",
                    "import { env } from '../env';",
                }
                read_stub:returns(file_content)

                local new_content = table.concat({
                    "import type { QueryClient } from '@tanstack/react-query';",
                    "import { useQueryClient } from '@tanstack/react-query';",
                    "",
                    "import { useAuthState } from '@org/auth/react';",
                    "import { useRouterAdapter } from '@org/routing';",
                    "",
                    "import { env } from '../env';",
                }, "\n")

                local blocks = ToolCallDiff.extract_diff_blocks({
                    path = "/test.tsx",
                    old_text = nil,
                    new_text = new_content,
                })

                -- Should have blocks (vim.diff finds the changes)
                assert.is_true(#blocks > 0)
                -- First block should start at line 1
                assert.equal(1, blocks[1].start_line)
            end
        )

        it("handles single line modification", function()
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

        it("handles replace_all option", function()
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

            -- Should find both occurrences
            assert.equal(2, #blocks)
            assert.equal(1, blocks[1].start_line)
            assert.equal(3, blocks[2].start_line)
        end)

        it("handles vim.NIL as nil for old_text", function()
            read_stub:returns(nil)

            local blocks = ToolCallDiff.extract_diff_blocks({
                path = "/new_file.lua",
                old_text = vim.NIL,
                new_text = "new content",
            })

            assert.equal(1, #blocks)
            assert.equal(0, #blocks[1].old_lines)
        end)
    end)
end)
