local assert = require("tests.helpers.assert")

describe("DiffSplitView", function()
    local DiffSplitView = require("agentic.ui.diff_split_view")

    local test_file_path = "/tmp/test_diff_split_view.lua"
    local test_tabpage

    before_each(function()
        vim.fn.writefile({ "local x = 1", "print(x)" }, test_file_path)
        vim.cmd("tabnew")
        test_tabpage = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        pcall(vim.fn.delete, test_file_path)
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
            "should fallback to inline mode for new files (empty old)",
            function()
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
