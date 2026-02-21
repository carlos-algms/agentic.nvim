local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")

describe("DiffSplitView", function()
    local DiffSplitView = require("agentic.ui.diff_split_view")
    local FileSystem = require("agentic.utils.file_system")

    local test_file_path = "/tmp/test_diff_split_view_fake.lua"
    local test_tabpage
    local read_stub

    --- @param lines string[]|nil
    local function stub_file_content(lines)
        read_stub:returns(lines, nil)
    end

    before_each(function()
        read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
        stub_file_content({ "local x = 1", "print(x)", "" })
        vim.cmd("tabnew")
        test_tabpage = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        read_stub:revert()
        if test_tabpage and vim.api.nvim_tabpage_is_valid(test_tabpage) then
            pcall(DiffSplitView.clear_split_diff, test_tabpage)
            pcall(vim.api.nvim_tabpage_del, test_tabpage)
        end
    end)

    --- @return number bufnr
    --- @return number tabpage
    local function setup_and_show_split()
        local bufnr = vim.fn.bufadd(test_file_path)

        DiffSplitView.show_split_diff({
            file_path = test_file_path,
            diff = { old = { "local x = 1" }, new = { "local x = 2" } },
            get_winid = function()
                return vim.api.nvim_get_current_win()
            end,
        })

        return bufnr, test_tabpage
    end

    describe("show_split_diff", function()
        it(
            "should fallback to inline mode for new files (empty old, file does not exist)",
            function()
                stub_file_content(nil)

                local success = DiffSplitView.show_split_diff({
                    file_path = test_file_path,
                    diff = { old = {}, new = { "local y = 2" } },
                    get_winid = function()
                        return vim.api.nvim_get_current_win()
                    end,
                })

                assert.is_false(success)
            end
        )

        it(
            "should fallback for empty old and new (Write tool initial call)",
            function()
                stub_file_content(nil)

                local success = DiffSplitView.show_split_diff({
                    file_path = test_file_path,
                    diff = { old = {}, new = { "" } },
                    get_winid = function()
                        return vim.api.nvim_get_current_win()
                    end,
                })

                assert.is_false(success)
            end
        )

        it(
            "should show split diff for full file replacement (empty old, file exists)",
            function()
                -- Load the buffer so the lightweight existence check succeeds
                local bufnr = vim.fn.bufadd(test_file_path)
                vim.fn.bufload(bufnr)

                local success = DiffSplitView.show_split_diff({
                    file_path = test_file_path,
                    diff = { old = {}, new = { "local y = 2" } },
                    get_winid = function()
                        return vim.api.nvim_get_current_win()
                    end,
                })

                assert.is_true(success)

                local state = DiffSplitView.get_split_state(test_tabpage)
                assert.is_not_nil(state)

                if state then
                    local new_lines = vim.api.nvim_buf_get_lines(
                        state.new_bufnr,
                        0,
                        -1,
                        false
                    )
                    assert.same({ "local y = 2" }, new_lines)
                end
            end
        )

        it(
            "should create split view with correct state and buffer options",
            function()
                local bufnr, tabpage = setup_and_show_split()
                local state = DiffSplitView.get_split_state(tabpage)

                assert.is_not_nil(state)
                if state then
                    assert.is_not_nil(state.original_winid)
                    assert.is_not_nil(state.new_winid)
                    assert.equal(bufnr, state.original_bufnr)
                    assert.is_not_nil(state.new_bufnr)
                    assert.is_not_nil(state.file_path)

                    assert.is_false(vim.bo[state.original_bufnr].modifiable)
                    assert.is_true(vim.bo[state.original_bufnr].modified)
                    assert.is_false(vim.bo[state.new_bufnr].modifiable)
                end
            end
        )

        it("should reconstruct full file from partial diff", function()
            stub_file_content({ "local x = 1", "local y = 2", "print(x)", "" })

            local success = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = {
                    old = { "local y = 2" },
                    new = { "local y = 3" },
                },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            assert.is_true(success)

            local state = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state)

            if state then
                local lines =
                    vim.api.nvim_buf_get_lines(state.new_bufnr, 0, -1, false)
                assert.same(
                    { "local x = 1", "local y = 3", "print(x)", "" },
                    lines
                )
            end
        end)

        it("should reconstruct file with multi-line replacement", function()
            stub_file_content({
                "local x = 1",
                "local y = 2",
                "local z = 3",
                "print(x)",
                "",
            })

            local success = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = {
                    old = { "local y = 2", "local z = 3" },
                    new = { "local a = 10", "local b = 20", "local c = 30" },
                },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            assert.is_true(success)

            local state = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state)

            if state then
                local lines =
                    vim.api.nvim_buf_get_lines(state.new_bufnr, 0, -1, false)
                assert.same({
                    "local x = 1",
                    "local a = 10",
                    "local b = 20",
                    "local c = 30",
                    "print(x)",
                    "",
                }, lines)
            end
        end)

        it("should return false when diff cannot be matched", function()
            local get_winid_spy = spy_module.new(function()
                return vim.api.nvim_get_current_win()
            end)

            local success = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = {
                    old = { "nonexistent line content" },
                    new = { "replacement" },
                },
                get_winid = get_winid_spy --[[@as function]],
            })

            assert.is_false(success)
            assert.is_nil(DiffSplitView.get_split_state(test_tabpage))
            assert.spy(get_winid_spy).was.called(0)
            get_winid_spy:revert()
        end)

        it("should handle substring fallback for single-line diffs", function()
            local success = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = {
                    old = { "x = 1" },
                    new = { "x = 2" },
                },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            assert.is_true(success)

            local state = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state)

            if state then
                local lines =
                    vim.api.nvim_buf_get_lines(state.new_bufnr, 0, -1, false)
                assert.same({ "local x = 2", "print(x)", "" }, lines)
            end
        end)

        it("should replace all matches when replace_all is true", function()
            stub_file_content({ "print(a)", "print(b)", "print(a)", "" })

            local success = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = {
                    old = { "print(a)" },
                    new = { "print(c)" },
                    all = true,
                },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            assert.is_true(success)

            local state = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state)

            if state then
                local lines =
                    vim.api.nvim_buf_get_lines(state.new_bufnr, 0, -1, false)
                assert.same({ "print(c)", "print(b)", "print(c)", "" }, lines)
            end
        end)

        it(
            "should replace only first match when replace_all is not set",
            function()
                stub_file_content({ "print(a)", "print(b)", "print(a)", "" })

                local success = DiffSplitView.show_split_diff({
                    file_path = test_file_path,
                    diff = {
                        old = { "print(a)" },
                        new = { "print(c)" },
                    },
                    get_winid = function()
                        return vim.api.nvim_get_current_win()
                    end,
                })

                assert.is_true(success)

                local state = DiffSplitView.get_split_state(test_tabpage)
                assert.is_not_nil(state)

                if state then
                    local lines = vim.api.nvim_buf_get_lines(
                        state.new_bufnr,
                        0,
                        -1,
                        false
                    )
                    assert.same(
                        { "print(c)", "print(b)", "print(a)", "" },
                        lines
                    )
                end
            end
        )
        it("should handle double-call without buffer/name collision", function()
            local bufnr = vim.fn.bufadd(test_file_path)
            local orig_modifiable = vim.bo[bufnr].modifiable

            local get_winid = function()
                return vim.api.nvim_get_current_win()
            end

            local first = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = get_winid,
            })
            assert.is_true(first)

            local state1 = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state1)

            local second = DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                get_winid = get_winid,
            })
            assert.is_true(second)

            local state2 = DiffSplitView.get_split_state(test_tabpage)
            assert.is_not_nil(state2)

            if state2 then
                assert.equal(bufnr, state2.original_bufnr)
                assert.is_true(vim.api.nvim_buf_is_valid(state2.new_bufnr))
                assert.is_true(vim.api.nvim_win_is_valid(state2.new_winid))

                local lines =
                    vim.api.nvim_buf_get_lines(state2.new_bufnr, 0, -1, false)
                assert.same({ "local x = 3", "print(x)", "" }, lines)
            end

            DiffSplitView.clear_split_diff(test_tabpage)
            assert.is_nil(DiffSplitView.get_split_state(test_tabpage))
            assert.equal(orig_modifiable, vim.bo[bufnr].modifiable)
        end)
    end)

    describe("clear_split_diff", function()
        it("should restore original buffer state and clear state", function()
            local bufnr = vim.fn.bufadd(test_file_path)

            local orig_modifiable = vim.bo[bufnr].modifiable
            local orig_modified = vim.bo[bufnr].modified

            DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            local tabpage = vim.api.nvim_get_current_tabpage()
            DiffSplitView.clear_split_diff(tabpage)

            assert.equal(orig_modifiable, vim.bo[bufnr].modifiable)
            assert.equal(orig_modified, vim.bo[bufnr].modified)
            assert.is_nil(DiffSplitView.get_split_state(tabpage))
        end)

        it(
            "should handle cleanup when scratch window already closed",
            function()
                local _, tabpage = setup_and_show_split()
                local state = DiffSplitView.get_split_state(tabpage)

                assert.is_not_nil(state)
                if state then
                    pcall(vim.api.nvim_win_close, state.new_winid, true)
                end

                assert.has_no_errors(function()
                    DiffSplitView.clear_split_diff(tabpage)
                end)
                assert.is_nil(DiffSplitView.get_split_state(tabpage))
            end
        )
    end)
end)
