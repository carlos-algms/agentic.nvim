local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.FileList", function()
    local FileList = require("agentic.ui.file_list")

    --- @type integer
    local bufnr
    --- @type agentic.ui.FileList
    local file_list
    --- @type TestSpy
    local on_change_spy
    --- @type TestStub
    local fs_stat_stub

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)

        fs_stat_stub = spy.stub(vim.uv, "fs_stat")
        fs_stat_stub:returns({ type = "file" })

        file_list = FileList:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        fs_stat_stub:revert()

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("add and get_files", function()
        it("adds valid file and retrieves it", function()
            local test_file = "/path/to/test.lua"

            local success = file_list:add(test_file)

            assert.is_true(success)

            local files = file_list:get_files()
            assert.equal(1, #files)
            assert.equal(test_file, files[1])
            assert.spy(on_change_spy).was.called(1)
            assert.stub(fs_stat_stub).was.called_with(test_file)
        end)

        it("does not add non-existent file", function()
            local non_existent = "/non/existent/file.lua"
            fs_stat_stub:returns(nil)

            local success = file_list:add(non_existent)

            assert.is_false(success)
            assert.is_true(file_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("does not add directory", function()
            local directory = "/path/to/directory"
            fs_stat_stub:returns({ type = "directory" })

            local success = file_list:add(directory)

            assert.is_false(success)
            assert.is_true(file_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("does not add duplicate file", function()
            local test_file = "/path/to/test.lua"

            file_list:add(test_file)
            file_list:add(test_file)

            local files = file_list:get_files()
            assert.equal(1, #files)
            assert.spy(on_change_spy).was.called(1)
        end)

        it("adds multiple distinct files", function()
            local file1 = "/path/to/file1.lua"
            local file2 = "/path/to/file2.lua"

            file_list:add(file1)
            file_list:add(file2)

            local files = file_list:get_files()
            assert.equal(2, #files)
            assert.equal(file1, files[1])
            assert.equal(file2, files[2])
            assert.spy(on_change_spy).was.called(2)
        end)

        it("returns deep copy of files", function()
            local test_file = "/path/to/test.lua"

            file_list:add(test_file)

            local files1 = file_list:get_files()
            local files2 = file_list:get_files()

            files1[1] = "modified"

            assert.equal(test_file, files2[1])
        end)
    end)

    describe("is_empty", function()
        it("returns true when no files added", function()
            assert.is_true(file_list:is_empty())
        end)

        it("returns false when files exist", function()
            file_list:add("/path/to/test.lua")

            assert.is_false(file_list:is_empty())
        end)
    end)

    describe("clear", function()
        it("removes all files", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")
            assert.is_false(file_list:is_empty())

            file_list:clear()

            assert.is_true(file_list:is_empty())
            assert.spy(on_change_spy).was.called(3)
        end)

        it("clears buffer content", function()
            file_list:add("/path/to/test.lua")

            local line_count = vim.api.nvim_buf_line_count(bufnr)
            assert.is_true(line_count > 0)

            file_list:clear()

            line_count = vim.api.nvim_buf_line_count(bufnr)
            assert.equal(1, line_count)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("", lines[1])
        end)
    end)

    describe("remove_file_at", function()
        it("removes file at valid index", function()
            local file1 = "/path/to/file1.lua"
            local file2 = "/path/to/file2.lua"

            file_list:add(file1)
            file_list:add(file2)

            assert.equal(2, #file_list:get_files())

            file_list:remove_file_at(1)

            local files = file_list:get_files()
            assert.equal(1, #files)
            assert.equal(file2, files[1])
            assert.spy(on_change_spy).was.called(3)
        end)

        it("does not remove at invalid index (too small)", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")

            file_list:remove_file_at(0)

            assert.equal(2, #file_list:get_files())
            assert.spy(on_change_spy).was.called(2)
        end)

        it("does not remove at invalid index (too large)", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")

            file_list:remove_file_at(3)

            assert.equal(2, #file_list:get_files())
            assert.spy(on_change_spy).was.called(2)
        end)

        it("removes second file when index is 2", function()
            local file1 = "/path/to/file1.lua"
            local file2 = "/path/to/file2.lua"

            file_list:add(file1)
            file_list:add(file2)

            file_list:remove_file_at(2)

            local files = file_list:get_files()
            assert.equal(1, #files)
            assert.equal(file1, files[1])
        end)

        it("removes all files when called sequentially", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")

            file_list:remove_file_at(1)
            file_list:remove_file_at(1)

            assert.is_true(file_list:is_empty())
        end)
    end)

    describe("to_prompt", function()
        local ACPPayloads = require("agentic.acp.acp_payloads")
        --- @type TestStub
        local create_file_content_stub

        before_each(function()
            create_file_content_stub =
                spy.stub(ACPPayloads, "create_file_content")
            create_file_content_stub:invokes(function(_path)
                return { type = "text", text = "stub" }
            end)
        end)

        after_each(function()
            create_file_content_stub:revert()
        end)

        it("emits image tags, @-mentions, and escapes <>", function()
            file_list:add("/tmp/photo.png")
            file_list:add("/tmp/photo with spaces).png")
            file_list:add("/tmp/photo <draft>.png")
            file_list:add("/tmp/code.lua")
            file_list:add("/tmp/diagram.SVG")

            local lines = file_list:to_prompt()
            local text = table.concat(lines, "\n")

            assert.equal("\n- **Referenced files**:", lines[1])
            -- image files render as markdown image tags so the chat
            -- buffer (markdown filetype) can display them inline.
            assert.is_not_nil(text:find("  - ![](</tmp/photo.png>)", 1, true))
            assert.is_not_nil(
                text:find("  - ![](</tmp/photo with spaces).png>)", 1, true)
            )
            assert.is_not_nil(
                text:find("  - ![](</tmp/photo \\<draft\\>.png>)", 1, true)
            )
            -- extension match is case-insensitive.
            assert.is_not_nil(text:find("  - ![](</tmp/diagram.SVG>)", 1, true))
            -- non-image files keep the original @-mention bullet.
            assert.is_not_nil(text:find("  %- @/tmp/code%.lua", 1))
        end)

        it("returns one prompt entry per file and clears the list", function()
            file_list:add("/tmp/a.lua")
            file_list:add("/tmp/b.lua")

            local _lines, prompt = file_list:to_prompt()

            assert.equal(2, #prompt)
            assert.stub(create_file_content_stub).was.called(2)
            assert.is_true(file_list:is_empty())
        end)
    end)

    describe("buffer rendering", function()
        it("renders file paths in buffer", function()
            local file1 = "/path/to/alpha.lua"
            local file2 = "/path/to/beta.lua"

            file_list:add(file1)
            file_list:add(file2)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(2, #lines)

            -- Verify actual file paths are in the buffer content
            local FileSystem = require("agentic.utils.file_system")
            local expected_path1 = FileSystem.to_smart_path(file1)
            local expected_path2 = FileSystem.to_smart_path(file2)

            assert.truthy(lines[1]:find(expected_path1, 1, true))
            assert.truthy(lines[2]:find(expected_path2, 1, true))
        end)

        it("updates buffer after removal", function()
            file_list:add("/path/to/file1.lua")
            file_list:add("/path/to/file2.lua")

            local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(2, #lines_before)

            file_list:remove_file_at(1)

            local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines_after)
        end)
    end)
end)
