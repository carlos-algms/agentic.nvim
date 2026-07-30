local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")
local DiffPreview = require("agentic.ui.diff_preview")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

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

            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if
                    bufnr ~= initial_bufnr and vim.api.nvim_buf_is_valid(bufnr)
                then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
            end

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
            -- new file: fs_stat nil from before_each
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

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.same(new_content, lines)

            assert.is_false(vim.bo[bufnr].buflisted)

            assert.equal(test_path, vim.b[bufnr]._agentic_suggestion_for)

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

                -- Buffer may exist via the normal diff path, but not as a
                -- suggestion buffer
                local bufnr = vim.fn.bufnr(test_path)
                if bufnr ~= -1 then
                    assert.is_nil(vim.b[bufnr]._agentic_suggestion_for)
                end
            end
        )

        it(
            "sets filetype on suggestion buffer for extensionless" .. " files",
            function()
                -- new file: fs_stat nil from before_each
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

                -- detected from the real path, not the buffer name
                local ft = vim.bo[bufnr].filetype
                assert.equal("make", ft)
            end
        )

        it(
            "silently skips diff when both old and new are empty (new file Write tool)",
            function()
                -- new file: does not exist
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

                assert.spy(get_winid_spy).was.called(0)
                -- silently: no warning
                assert.spy(notify_spy).was.called(0)
            end
        )
    end)

    describe("clear_diff", function()
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

                -- as show_diff does: save state, set read-only
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

                    -- as show_diff on an already non-modifiable buffer
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

            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "local M = {}", "return M" }
            )

            local NS_DIFF =
                vim.api.nvim_create_namespace("agentic_diff_preview")
            vim.api.nvim_buf_set_extmark(bufnr, NS_DIFF, 0, 0, {
                end_row = 0,
                end_col = 12,
                hl_group = "DiffAdd",
                hl_eol = true,
            })

            -- acceptance: is_rejection nil
            DiffPreview.clear_diff(bufnr)

            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.same({ "local M = {}", "return M" }, lines)

            local marks =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DIFF, 0, -1, {})
            assert.same({}, marks)

            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("deletes suggestion buffer on rejection", function()
            -- needs a window to display the buffer
            vim.cmd("enew")
            local alt_bufnr = vim.api.nvim_get_current_buf()

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/rejected.lua")
            vim.b[bufnr]._agentic_suggestion_for = "/tmp/rejected.lua"
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })

            vim.api.nvim_win_set_buf(0, bufnr)

            DiffPreview.clear_diff(bufnr, true)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))

            local current = vim.api.nvim_get_current_buf()
            assert.equal(alt_bufnr, current)

            if vim.api.nvim_buf_is_valid(alt_bufnr) then
                pcall(vim.api.nvim_buf_delete, alt_bufnr, { force = true })
            end
        end)

        it("rejects in the window the diff was painted in", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/rejected_painted.lua")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })

            -- Same buffer in two windows; only `preview_winid` marks the painted
            -- one. Defect: clearing state before reading it made the swap land
            -- in whichever window `win_findbuf` returned first.
            local other_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(other_win, bufnr)

            local painted_win = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                win = other_win,
            })

            --- @type agentic.ui.DiffState
            local state = { preview_bufnr = bufnr, preview_winid = painted_win }

            DiffPreview.clear_diff(bufnr, true, state)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(painted_win))
            assert.is_nil(state.preview_winid)

            pcall(vim.api.nvim_win_close, painted_win, true)
        end)

        it("keeps the user's other window open on rejection", function()
            -- `clear_diff` must swap EVERY window holding the rejected buffer,
            -- not just the painted one: `nvim_buf_delete(force)` closes the
            -- rest, taking the user's second window on the same file with it.
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/rejected_two_windows.lua")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })

            local other_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(other_win, bufnr)

            local painted_win = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                win = other_win,
            })

            --- @type agentic.ui.DiffState
            local state = { preview_bufnr = bufnr, preview_winid = painted_win }

            DiffPreview.clear_diff(bufnr, true, state)

            assert.is_true(vim.api.nvim_win_is_valid(other_win))

            pcall(vim.api.nvim_win_close, painted_win, true)
        end)

        it("clears only the state of the session that cleared", function()
            -- Two sessions previewing one file, each with its own `DiffState`
            -- (one per `DiffCoordinator`) painted in its own window. One
            -- session's clear must not touch the other's state, or the survivor
            -- loses the window its hunk navigation and rejection swap read.
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_name(bufnr, "/tmp/two_sessions_one_file.lua")
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "content" })

            local win_a = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win_a, bufnr)

            local win_b = vim.api.nvim_open_win(bufnr, false, {
                split = "below",
                win = win_a,
            })

            --- @type agentic.ui.DiffState
            local state_a = { preview_bufnr = bufnr, preview_winid = win_a }
            --- @type agentic.ui.DiffState
            local state_b = { preview_bufnr = bufnr, preview_winid = win_b }

            -- Acceptance, not rejection: buffer is the user's real file, both
            -- sessions keep looking at it.
            DiffPreview.clear_diff(bufnr, false, state_a)

            assert.is_nil(state_a.preview_bufnr)
            assert.is_nil(state_a.preview_winid)
            assert.equal(bufnr, state_b.preview_bufnr)
            assert.equal(win_b, state_b.preview_winid)
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(win_a))
            assert.is_true(vim.api.nvim_win_is_valid(win_b))

            pcall(vim.api.nvim_win_close, win_b, true)
        end)
    end)
end)
