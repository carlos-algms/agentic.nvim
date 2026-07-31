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

--- @param bufnr integer
--- @param lhs string
--- @return boolean found
local function has_buffer_keymap(bufnr, lhs)
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if keymap.lhs == lhs then
            return true
        end
    end
    return false
end

describe("diff_preview", function()
    --- @type integer
    local outer_baseline_bufnr

    before_each(function()
        outer_baseline_bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        assert.is_true(vim.api.nvim_buf_is_valid(outer_baseline_bufnr))
        vim.api.nvim_buf_delete(outer_baseline_bufnr, { force = true })
    end)

    describe("show_diff", function()
        local read_stub
        local get_winid_spy
        local notify_spy
        local fs_stat_stub
        local orig_layout
        --- @type table<integer, true>
        local base_tabs
        --- @type table<integer, true>
        local base_bufs

        --- @type integer|nil
        local initial_bufnr

        before_each(function()
            initial_bufnr = vim.api.nvim_get_current_buf()
            base_tabs = {}
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                base_tabs[tab] = true
            end
            base_bufs = {}
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                base_bufs[bufnr] = true
            end
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
                    not base_bufs[bufnr] and vim.api.nvim_buf_is_valid(bufnr)
                then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
            end

            if initial_bufnr and vim.api.nvim_buf_is_valid(initial_bufnr) then
                pcall(vim.api.nvim_win_set_buf, 0, initial_bufnr)
            end
            close_extra_tabs(base_tabs)
        end)

        --- @param test_path string
        --- @param state agentic.ui.DiffState
        --- @param new_line string
        --- @return integer bufnr
        local function show_existing_diff(test_path, state, new_line)
            fs_stat_stub:returns({ type = "file" })
            read_stub:invokes(function()
                return { "local x = 1", "print(x)", "" }, nil
            end)

            local bufnr = vim.fn.bufadd(test_path)
            vim.fn.bufload(bufnr)
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "local x = 1", "print(x)", "" }
            )
            vim.api.nvim_win_set_buf(0, bufnr)

            DiffPreview.show_diff({
                file_path = test_path,
                diff = {
                    old = { "local x = 1" },
                    new = { new_line },
                },
                state = state,
                get_winid = get_winid_spy --[[@as function]],
            })

            return bufnr
        end

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

        it("isolates same-path suggestion previews by session state", function()
            read_stub:invokes(function()
                return nil
            end)

            local test_path = "/tmp/test_shared_suggestion.lua"
            --- @type agentic.ui.DiffState
            local state_a = {}
            --- @type agentic.ui.DiffState
            local state_b = {}

            local win_a = vim.api.nvim_get_current_win()
            vim.cmd("tabnew")
            local win_b = vim.api.nvim_get_current_win()

            local function show_in(winid, state, value)
                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = { old = {}, new = { value } },
                    state = state,
                    get_winid = function(bufnr)
                        vim.api.nvim_win_set_buf(winid, bufnr)
                        return winid
                    end,
                })
            end

            show_in(win_a, state_a, "session a")
            show_in(win_b, state_b, "session b")

            assert.is_not_nil(state_a.preview_bufnr)
            assert.is_not_nil(state_b.preview_bufnr)
            assert.is_not.equal(state_a.preview_bufnr, state_b.preview_bufnr)
            assert.is_not.equal(
                vim.api.nvim_buf_get_name(state_a.preview_bufnr),
                vim.api.nvim_buf_get_name(state_b.preview_bufnr)
            )
            assert.is_true(
                has_buffer_keymap(
                    state_a.preview_bufnr,
                    Config.keymaps.diff_preview.next_hunk
                )
            )
            assert.is_true(
                has_buffer_keymap(
                    state_b.preview_bufnr,
                    Config.keymaps.diff_preview.next_hunk
                )
            )

            local state_b_bufnr = state_b.preview_bufnr
            ---@cast state_b_bufnr integer
            DiffPreview.clear_diff(test_path, true, state_a)

            assert.is_nil(state_a.preview_bufnr)
            assert.equal(state_b_bufnr, state_b.preview_bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(state_b_bufnr))
            assert.equal(
                "session b",
                vim.api.nvim_buf_get_lines(state_b_bufnr, 0, 1, false)[1]
            )
            assert.is_true(
                has_buffer_keymap(
                    state_b_bufnr,
                    Config.keymaps.diff_preview.next_hunk
                )
            )

            DiffPreview.clear_diff(test_path, true, state_b)
        end)

        it("skips a second inline owner for an existing-file buffer", function()
            local test_path = "/tmp/test_existing_inline_owner.lua"
            --- @type agentic.ui.DiffState
            local state_a = {}
            --- @type agentic.ui.DiffState
            local state_b = {}
            local bufnr = show_existing_diff(test_path, state_a, "local x = 2")

            DiffPreview.show_diff({
                file_path = test_path,
                diff = {
                    old = { "local x = 1" },
                    new = { "local x = 3" },
                },
                state = state_b,
                get_winid = get_winid_spy --[[@as function]],
            })

            assert.equal(
                tostring(state_a),
                vim.b[bufnr]._agentic_inline_diff_owner
            )
            assert.is_nil(state_b.preview_bufnr)
            assert.is_nil(state_b.preview_winid)
        end)

        it(
            "preserves the first inline owner's resources after rejection",
            function()
                local test_path = "/tmp/test_existing_inline_resources.lua"
                --- @type agentic.ui.DiffState
                local state_a = {}
                --- @type agentic.ui.DiffState
                local state_b = {}
                local bufnr =
                    show_existing_diff(test_path, state_a, "local x = 2")
                local marks_before = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    -1,
                    0,
                    -1,
                    { details = true }
                )
                local winid = state_a.preview_winid

                DiffPreview.clear_diff(bufnr, false, state_b)

                assert.equal(
                    tostring(state_a),
                    vim.b[bufnr]._agentic_inline_diff_owner
                )
                assert.equal(bufnr, state_a.preview_bufnr)

                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = {
                        old = { "local x = 1" },
                        new = { "local x = 3" },
                    },
                    state = state_b,
                    get_winid = get_winid_spy --[[@as function]],
                })

                assert.same(
                    marks_before,
                    vim.api.nvim_buf_get_extmarks(
                        bufnr,
                        -1,
                        0,
                        -1,
                        { details = true }
                    )
                )
                assert.is_false(vim.bo[bufnr].modifiable)
                assert.is_true(
                    has_buffer_keymap(
                        bufnr,
                        Config.keymaps.diff_preview.next_hunk
                    )
                )
                assert.equal(bufnr, state_a.preview_bufnr)
                assert.equal(winid, state_a.preview_winid)

                DiffPreview.clear_diff(bufnr, false, state_a)

                assert.is_nil(vim.b[bufnr]._agentic_inline_diff_owner)
                assert.is_true(vim.bo[bufnr].modifiable)

                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = {
                        old = { "local x = 1" },
                        new = { "local x = 3" },
                    },
                    state = state_b,
                    get_winid = get_winid_spy --[[@as function]],
                })

                assert.equal(
                    tostring(state_b),
                    vim.b[bufnr]._agentic_inline_diff_owner
                )
                assert.equal(bufnr, state_b.preview_bufnr)
            end
        )

        it(
            "refreshes an existing-file inline diff for the same owner",
            function()
                local test_path = "/tmp/test_existing_inline_refresh.lua"
                --- @type agentic.ui.DiffState
                local state = {}
                local bufnr =
                    show_existing_diff(test_path, state, "local x = 2")

                DiffPreview.show_diff({
                    file_path = test_path,
                    diff = {
                        old = { "local x = 1" },
                        new = { "local x = 3" },
                    },
                    state = state,
                    get_winid = get_winid_spy --[[@as function]],
                })

                local marks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    -1,
                    0,
                    -1,
                    { details = true }
                )
                local refreshed = false
                for _, mark in ipairs(marks) do
                    local virt_lines = mark[4].virt_lines
                    if virt_lines and virt_lines[1] then
                        local segments = {}
                        for _, segment in ipairs(virt_lines[1]) do
                            segments[#segments + 1] = segment[1]
                        end
                        refreshed = table.concat(segments) == "local x = 3"
                    end
                end
                assert.equal(
                    tostring(state),
                    vim.b[bufnr]._agentic_inline_diff_owner
                )
                assert.equal(bufnr, state.preview_bufnr)
                assert.is_true(refreshed)
            end
        )

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
        --- @type integer[]
        local created_wins
        --- @type integer[]
        local created_bufs
        --- @type table<integer, true>
        local base_tabs
        --- @type integer
        local augroup

        before_each(function()
            created_wins = {}
            created_bufs = {}
            base_tabs = {}
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                base_tabs[tab] = true
            end
            augroup = vim.api.nvim_create_augroup(
                "agentic_diff_preview_test",
                { clear = true }
            )
        end)

        after_each(function()
            -- A leaked autocmd corrupts every later test file.
            pcall(vim.api.nvim_del_augroup_by_id, augroup)
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
            local bufnr = new_named_buf("/tmp/rejected_painted.lua")
            local other_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(other_win, bufnr)
            local painted_win = split_showing(bufnr, other_win)
            --- @type agentic.ui.DiffState
            local state = { preview_bufnr = bufnr, preview_winid = painted_win }

            DiffPreview.clear_diff(bufnr, true, state)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(painted_win))
            assert.is_nil(state.preview_winid)
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

        it("finishes the rejection when a window dies mid-loop", function()
            local bufnr = new_named_buf("/tmp/rejected_dying_window.lua")
            local alt = new_named_buf("/tmp/dying_alternate.lua")

            local first_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(first_win, alt)
            vim.api.nvim_win_set_buf(first_win, bufnr)

            local second_win = split_showing(alt, first_win)
            vim.api.nvim_win_set_buf(second_win, bufnr)

            local third_win = split_showing(alt, first_win)
            vim.api.nvim_win_set_buf(third_win, bufnr)

            -- `win_findbuf` snapshots the window list up front; swapping the
            -- first window fires autocmds that can kill a LATER entry.
            vim.api.nvim_create_autocmd("BufEnter", {
                group = augroup,
                buffer = alt,
                callback = function()
                    if vim.api.nvim_win_is_valid(third_win) then
                        vim.api.nvim_win_close(third_win, true)
                    end
                end,
            })

            DiffPreview.clear_diff(bufnr, true)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(first_win))
            assert.is_true(vim.api.nvim_win_is_valid(second_win))
            assert.equal(alt, vim.api.nvim_win_get_buf(first_win))
            assert.equal(alt, vim.api.nvim_win_get_buf(second_win))
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

        it("clears only the state of the session that cleared", function()
            local bufnr = new_named_buf("/tmp/two_sessions_one_file.lua")
            local win_a = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win_a, bufnr)
            local win_b = split_showing(bufnr, win_a)
            --- @type agentic.ui.DiffState
            local state_a = { preview_bufnr = bufnr, preview_winid = win_a }
            --- @type agentic.ui.DiffState
            local state_b = { preview_bufnr = bufnr, preview_winid = win_b }

            DiffPreview.clear_diff(bufnr, false, state_a)

            assert.is_nil(state_a.preview_bufnr)
            assert.is_nil(state_a.preview_winid)
            assert.equal(bufnr, state_b.preview_bufnr)
            assert.equal(win_b, state_b.preview_winid)
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(win_a))
            assert.is_true(vim.api.nvim_win_is_valid(win_b))
        end)

        it("cleans only the owning session's same-path suggestion", function()
            local file_path = "/tmp/shared_cleanup_suggestion.lua"
            local suggestion_a = new_named_buf(
                FileSystem.to_smart_path(file_path) .. " (suggestion a)"
            )
            local suggestion_b = new_named_buf(
                FileSystem.to_smart_path(file_path) .. " (suggestion b)"
            )
            vim.b[suggestion_a]._agentic_suggestion_for = file_path
            vim.b[suggestion_b]._agentic_suggestion_for = file_path

            --- @type agentic.ui.DiffState
            local state_a = { preview_bufnr = suggestion_a }
            --- @type agentic.ui.DiffState
            local state_b = { preview_bufnr = suggestion_b }

            DiffPreview.cleanup_suggestion_buffer(file_path, state_a)

            assert.is_false(vim.api.nvim_buf_is_valid(suggestion_a))
            assert.is_nil(state_a.preview_bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(suggestion_b))
            assert.equal(suggestion_b, state_b.preview_bufnr)
        end)
    end)
end)
