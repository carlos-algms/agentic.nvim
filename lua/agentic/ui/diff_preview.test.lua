local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")
local DiffPreview = require("agentic.ui.diff_preview")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- Closes every tabpage absent from the baseline set. Counting tabpages and
--- closing the *current* one can shut a baseline tab while a created one lives.
--- @param base_tabs table<integer, true>
local function close_extra_tabs(base_tabs)
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if not base_tabs[tab] and vim.api.nvim_tabpage_is_valid(tab) then
            pcall(function()
                vim.api.nvim_set_current_tabpage(tab)
                vim.cmd("tabclose!")
            end)
        end
    end
end

describe("diff_preview", function()
    describe("show_diff", function()
        local read_stub
        local get_winid_spy
        local notify_spy
        local fs_stat_stub
        local orig_layout

        --- @type integer|nil
        local initial_bufnr

        before_each(function()
            initial_bufnr = vim.api.nvim_get_current_buf()
            read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
            read_stub:invokes(function()
                return { "local x = 1", "print(x)", "" }, nil
            end)
            get_winid_spy = spy_module.new(function()
                return vim.api.nvim_get_current_win()
            end)
            notify_spy = spy_module.on(Logger, "notify")
            fs_stat_stub = spy_module.stub(vim.uv, "fs_stat")
            fs_stat_stub:returns(nil)
            orig_layout = Config.diff_preview.layout
            Config.diff_preview.layout = "inline"
        end)

        after_each(function()
            read_stub:revert()
            get_winid_spy:revert()
            notify_spy:revert()
            fs_stat_stub:revert()
            Config.diff_preview.layout = orig_layout

            -- Clean up any buffers created during test
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if
                    bufnr ~= initial_bufnr and vim.api.nvim_buf_is_valid(bufnr)
                then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
            end

            -- Restore initial buffer in current window
            if initial_bufnr and vim.api.nvim_buf_is_valid(initial_bufnr) then
                pcall(vim.api.nvim_win_set_buf, 0, initial_bufnr)
            end
        end)

        it("should not open a window when diff matching fails", function()
            DiffPreview.show_diff({
                file_path = "/tmp/test_diff_preview_nomatch.lua",
                diff = {
                    old = { "nonexistent content that wont match" },
                    new = { "replacement" },
                },
                get_winid = get_winid_spy --[[@as function]],
            })

            assert.spy(get_winid_spy).was.called(0)
        end)

        it("creates suggestion buffer with real text for new files", function()
            -- fs_stat already stubbed to return nil in before_each
            read_stub:invokes(function()
                return nil
            end)

            local test_path = "/tmp/test_new_file_suggestion.lua"
            local new_content = { "local M = {}", "return M" }

            DiffPreview.show_diff({
                file_path = test_path,
                diff = {
                    old = {},
                    new = new_content,
                },
                get_winid = get_winid_spy --[[@as function]],
            })

            local bufnr = vim.fn.bufnr(test_path)
            assert.is_true(bufnr ~= -1)

            -- Buffer should contain real text, not be empty
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.same(new_content, lines)

            -- Buffer should be unlisted
            assert.is_false(vim.bo[bufnr].buflisted)

            -- Buffer should have _agentic_suggestion_for set
            assert.equal(test_path, vim.b[bufnr]._agentic_suggestion_for)

            -- Buffer should not be modifiable
            assert.is_false(vim.bo[bufnr].modifiable)
        end)

        it(
            "does NOT create suggestion buffer when file exists"
                .. " (Write tool overwrite)",
            function()
                fs_stat_stub:returns({ type = "file" })

                read_stub:invokes(function()
                    return { "old content" }, nil
                end)

                local test_path = "/tmp/test_existing_overwrite.lua"

                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = {
                        old = {},
                        new = { "new content" },
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                -- Buffer may exist (normal diff path), but should
                -- NOT be a suggestion buffer
                local bufnr = vim.fn.bufnr(test_path)
                if bufnr ~= -1 then
                    assert.is_nil(vim.b[bufnr]._agentic_suggestion_for)
                end
            end
        )

        it(
            "sets filetype on suggestion buffer for extensionless" .. " files",
            function()
                -- fs_stat already stubbed to return nil in before_each
                read_stub:invokes(function()
                    return nil
                end)

                local test_path = "/tmp/Makefile"

                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = {
                        old = {},
                        new = { "all: build" },
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                local bufnr = vim.fn.bufnr(test_path)
                assert.is_true(bufnr ~= -1)

                -- Filetype should be detected from the real path
                local ft = vim.bo[bufnr].filetype
                assert.equal("make", ft)
            end
        )

        it(
            "silently skips diff when both old and new are empty (new file Write tool)",
            function()
                -- Simulate new file: file doesn't exist
                read_stub:invokes(function()
                    return nil
                end)

                DiffPreview.show_diff({
                    file_path = "/tmp/test_new_file.md",
                    diff = {
                        old = {},
                        new = { "" },
                    },
                    get_winid = get_winid_spy --[[@as function]],
                })

                -- Should not open a window
                assert.spy(get_winid_spy).was.called(0)
                -- Should not show a warning notification
                assert.spy(notify_spy).was.called(0)
            end
        )
    end)

    describe("clear_diff", function()
        --- @type integer[]
        local created_wins
        --- @type integer[]
        local created_bufs
        --- @type table<integer, true>
        local base_tabs

        before_each(function()
            created_wins = {}
            created_bufs = {}
            base_tabs = {}
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                base_tabs[tab] = true
            end
        end)

        after_each(function()
            for _, winid in ipairs(created_wins) do
                pcall(vim.api.nvim_win_close, winid, true)
            end
            for _, bufnr in ipairs(created_bufs) do
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
            close_extra_tabs(base_tabs)
        end)

        --- @param name string
        --- @return integer bufnr
        local function new_named_buf(name)
            local bufnr = vim.api.nvim_create_buf(false, true)
            created_bufs[#created_bufs + 1] = bufnr
            vim.api.nvim_buf_set_name(bufnr, name)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })
            return bufnr
        end

        --- @param bufnr integer
        --- @param parent integer
        --- @return integer winid
        local function split_showing(bufnr, parent)
            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                win = parent,
            })
            created_wins[#created_wins + 1] = winid
            return winid
        end

        it("clears the diff without any error", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            assert.has_no_errors(function()
                DiffPreview.clear_diff(bufnr)
            end)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "switches to alternate buffer when clearing unsaved named buffer",
            function()
                vim.cmd("edit tests/init.lua")
                local init_bufnr = vim.api.nvim_get_current_buf()

                vim.cmd("enew")
                local new_bufnr = vim.api.nvim_get_current_buf()

                local current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, new_bufnr)

                vim.cmd("file tests/my_new_test.lua")

                DiffPreview.clear_diff(new_bufnr, true)

                current_bufnr = vim.api.nvim_get_current_buf()
                assert.equal(current_bufnr, init_bufnr)

                if vim.api.nvim_buf_is_valid(new_bufnr) then
                    pcall(vim.api.nvim_buf_delete, new_bufnr, { force = true })
                end
                if vim.api.nvim_buf_is_valid(init_bufnr) then
                    pcall(vim.api.nvim_buf_delete, init_bufnr, { force = true })
                end
            end
        )

        describe("set and revert modifiable buffer option", function()
            it("restores modifiable state after clearing diff", function()
                local bufnr = vim.api.nvim_create_buf(false, true)
                vim.bo[bufnr].modifiable = true

                -- Simulate what show_diff does: save state and set read-only
                vim.b[bufnr]._agentic_prev_modifiable = true
                vim.bo[bufnr].modifiable = false

                assert.is_false(vim.bo[bufnr].modifiable)

                DiffPreview.clear_diff(bufnr)

                assert.is_true(vim.bo[bufnr].modifiable)
                assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)

            it(
                "preserves non-modifiable state if buffer was already read-only",
                function()
                    local bufnr = vim.api.nvim_create_buf(false, true)
                    vim.bo[bufnr].modifiable = false

                    -- Simulate show_diff on already non-modifiable buffer
                    vim.b[bufnr]._agentic_prev_modifiable = false
                    vim.bo[bufnr].modifiable = false

                    DiffPreview.clear_diff(bufnr)

                    assert.is_false(vim.bo[bufnr].modifiable)
                    assert.is_nil(vim.b[bufnr]._agentic_prev_modifiable)

                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            )
        end)

        it("clears only highlights on suggestion buffer acceptance", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/new.lua")
            vim.b[bufnr]._agentic_suggestion_for = "/tmp/new.lua"

            -- Write content
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "local M = {}", "return M" }
            )

            -- Add diff highlights
            local NS_DIFF =
                vim.api.nvim_create_namespace("agentic_diff_preview")
            vim.api.nvim_buf_set_extmark(bufnr, NS_DIFF, 0, 0, {
                end_row = 0,
                end_col = 12,
                hl_group = "DiffAdd",
                hl_eol = true,
            })

            -- Simulate acceptance (is_rejection = false/nil)
            DiffPreview.clear_diff(bufnr)

            -- Buffer should still exist and have content
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.same({ "local M = {}", "return M" }, lines)

            -- Extmarks should be cleared
            local marks =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DIFF, 0, -1, {})
            assert.same({}, marks)

            -- Cleanup
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("deletes suggestion buffer on rejection", function()
            -- Need a window to display the buffer
            vim.cmd("enew")
            local alt_bufnr = vim.api.nvim_get_current_buf()

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/rejected.lua")
            vim.b[bufnr]._agentic_suggestion_for = "/tmp/rejected.lua"
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })

            -- Display suggestion buffer in current window
            vim.api.nvim_win_set_buf(0, bufnr)

            DiffPreview.clear_diff(bufnr, true)

            -- Buffer should be deleted
            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))

            -- Window should show alternate buffer
            local current = vim.api.nvim_get_current_buf()
            assert.equal(alt_bufnr, current)

            -- Cleanup
            if vim.api.nvim_buf_is_valid(alt_bufnr) then
                pcall(vim.api.nvim_buf_delete, alt_bufnr, { force = true })
            end
        end)

        it("keeps the user's other window open on rejection", function()
            local bufnr = new_named_buf("/tmp/rejected_two_windows.lua")
            local first_alt = new_named_buf("/tmp/first_alternate.lua")
            local second_alt = new_named_buf("/tmp/second_alternate.lua")

            -- Each window gets its OWN alternate, so the swap must resolve `#`
            -- inside each window rather than reuse the current window's.
            local first_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(first_win, first_alt)
            vim.api.nvim_win_set_buf(first_win, bufnr)

            local second_win = split_showing(second_alt, first_win)
            vim.api.nvim_win_set_buf(second_win, bufnr)

            DiffPreview.clear_diff(bufnr, true)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(first_win))
            assert.is_true(vim.api.nvim_win_is_valid(second_win))
            assert.equal(first_alt, vim.api.nvim_win_get_buf(first_win))
            assert.equal(second_alt, vim.api.nvim_win_get_buf(second_win))
        end)

        it("keeps a window on the rejected file in another tabpage", function()
            local bufnr = new_named_buf("/tmp/rejected_other_tab.lua")

            local first_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(first_win, bufnr)

            vim.cmd("tabnew")
            local other_tab_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(other_tab_win, bufnr)
            vim.api.nvim_set_current_win(first_win)

            DiffPreview.clear_diff(bufnr, true)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(other_tab_win))
        end)

        it("deletes nothing when the rejected file exists on disk", function()
            local file_path = vim.fn.tempname()
            local ok = vim.fn.writefile({ "content" }, file_path)
            assert.equal(0, ok)

            local bufnr = vim.fn.bufadd(file_path)
            created_bufs[#created_bufs + 1] = bufnr
            vim.fn.bufload(bufnr)

            local winid = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(winid, bufnr)

            DiffPreview.clear_diff(bufnr, true)

            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.equal(bufnr, vim.api.nvim_win_get_buf(winid))

            vim.fn.delete(file_path)
        end)
    end)
end)
