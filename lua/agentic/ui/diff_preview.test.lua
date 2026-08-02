local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")
local DiffPreview = require("agentic.ui.diff_preview")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local DiffSplitView = require("agentic.ui.diff_split_view")
local HunkNavigation = require("agentic.ui.hunk_navigation")

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
        local schedule_stub
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
            schedule_stub = spy_module.stub(vim, "schedule")
            orig_layout = Config.diff_preview.layout
            Config.diff_preview.layout = "inline"
        end)

        after_each(function()
            read_stub:revert()
            get_winid_spy:revert()
            notify_spy:revert()
            fs_stat_stub:revert()
            schedule_stub:revert()
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

        it("skips split layout for the reserved nil-state owner", function()
            Config.diff_preview.layout = "split"
            local split_stub = spy_module.stub(DiffSplitView, "show_split_diff")
            local path = "/tmp/test_nil_state_split.lua"

            DiffPreview.show_diff({
                file_path = path,
                diff = { old = {}, new = { "return true" } },
                get_winid = get_winid_spy --[[@as function]],
            })

            local split_calls = split_stub.call_count
            local bufnr = vim.fn.bufnr(path)
            local found_navigation = false
            for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
                if keymap.lhs == Config.keymaps.diff_preview.next_hunk then
                    found_navigation = true
                end
            end
            split_stub:revert()
            assert.equal(0, split_calls)
            assert.is_true(found_navigation)
        end)
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
        local bufnr_stub

        before_each(function()
            created_wins = {}
            created_bufs = {}
            bufnr_stub = nil
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
            if bufnr_stub then
                bufnr_stub:revert()
                bufnr_stub = nil
            end
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

        --- @param bufnr integer
        local function mark_legacy_owner(bufnr)
            vim.b[bufnr]._agentic_inline_diff_owner = "legacy"
        end

        it("clears the diff without any error", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            mark_legacy_owner(bufnr)

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
                mark_legacy_owner(new_bufnr)

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
                mark_legacy_owner(bufnr)
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
                    mark_legacy_owner(bufnr)
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
            mark_legacy_owner(bufnr)

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
            mark_legacy_owner(bufnr)
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
            vim.b[bufnr]._agentic_inline_diff_owner = tostring(state)

            DiffPreview.clear_diff(bufnr, true, state)

            assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(painted_win))
            assert.is_nil(state.preview_winid)
        end)

        it(
            "uses an unlisted placeholder without an alternate buffer",
            function()
                local bufnr =
                    new_named_buf("/tmp/rejected_without_alternate.lua")
                mark_legacy_owner(bufnr)
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, bufnr)
                bufnr_stub = spy_module.stub(vim.fn, "bufnr")
                bufnr_stub:returns(-1)

                DiffPreview.clear_diff(bufnr, true)

                local replacement_bufnr = vim.api.nvim_win_get_buf(winid)
                local replacement_listed = vim.bo[replacement_bufnr].buflisted
                bufnr_stub:revert()
                bufnr_stub = nil
                created_bufs[#created_bufs + 1] = replacement_bufnr
                assert.is_false(replacement_listed)
            end
        )

        it("keeps the user's other window open on rejection", function()
            local bufnr = new_named_buf("/tmp/rejected_two_windows.lua")
            mark_legacy_owner(bufnr)
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
            mark_legacy_owner(bufnr)
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
            mark_legacy_owner(bufnr)

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
            mark_legacy_owner(bufnr)

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
            vim.b[bufnr]._agentic_inline_diff_owner = tostring(state_a)

            DiffPreview.clear_diff(bufnr, false, state_a)

            assert.is_nil(state_a.preview_bufnr)
            assert.is_nil(state_a.preview_winid)
            assert.equal(bufnr, state_b.preview_bufnr)
            assert.equal(win_b, state_b.preview_winid)
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(win_a))
            assert.is_true(vim.api.nvim_win_is_valid(win_b))
        end)

        it(
            "keeps a newer same-session preview when an older result clears",
            function()
                local older_bufnr = new_named_buf("/tmp/older_preview.lua")
                local newer_bufnr = new_named_buf("/tmp/newer_preview.lua")
                local newer_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(newer_win, newer_bufnr)
                --- @type agentic.ui.DiffState
                local state = {
                    preview_bufnr = newer_bufnr,
                    preview_winid = newer_win,
                }
                vim.b[older_bufnr]._agentic_inline_diff_owner = tostring(state)

                DiffPreview.clear_diff(older_bufnr, false, state)

                assert.equal(newer_bufnr, state.preview_bufnr)
                assert.equal(newer_win, state.preview_winid)
            end
        )

        it("cleans only the owning session's same-path suggestion", function()
            local file_path = "/tmp/shared_cleanup_suggestion.lua"
            --- @type agentic.ui.DiffState
            local state_a = {}
            --- @type agentic.ui.DiffState
            local state_b = {}
            local smart_path = FileSystem.to_smart_path(file_path)
            local suggestion_a = new_named_buf(
                string.format(
                    "%s (suggestion %s)",
                    smart_path,
                    tostring(state_a):gsub("^table: ", "")
                )
            )
            local suggestion_b = new_named_buf(
                string.format(
                    "%s (suggestion %s)",
                    smart_path,
                    tostring(state_b):gsub("^table: ", "")
                )
            )
            vim.b[suggestion_a]._agentic_suggestion_for = file_path
            vim.b[suggestion_b]._agentic_suggestion_for = file_path
            vim.b[suggestion_a]._agentic_inline_diff_owner = tostring(state_a)
            vim.b[suggestion_b]._agentic_inline_diff_owner = tostring(state_b)
            state_a.preview_bufnr = suggestion_a
            state_b.preview_bufnr = suggestion_b

            DiffPreview.cleanup_suggestion_buffer(file_path, state_a)

            assert.is_false(vim.api.nvim_buf_is_valid(suggestion_a))
            assert.is_nil(state_a.preview_bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(suggestion_b))
            assert.equal(suggestion_b, state_b.preview_bufnr)
        end)
    end)
end)

describe("diff_preview owner isolation", function()
    local read_stub
    local fs_stat_stub
    local schedule_stub
    local saved_layout
    local base_tabs
    local base_bufs
    local clear_state_spy

    before_each(function()
        base_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tabpage] = true
        end
        base_bufs = {}
        clear_state_spy = nil
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            base_bufs[bufnr] = true
        end
        saved_layout = Config.diff_preview.layout
        Config.diff_preview.layout = "inline"
        read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
        read_stub:invokes(function()
            return { "local x = 1", "" }, nil
        end)
        fs_stat_stub = spy_module.stub(vim.uv, "fs_stat")
        fs_stat_stub:returns(nil)
        schedule_stub = spy_module.stub(vim, "schedule")
    end)

    after_each(function()
        if clear_state_spy then
            clear_state_spy:revert()
            clear_state_spy = nil
        end
        read_stub:revert()
        fs_stat_stub:revert()
        schedule_stub:revert()
        Config.diff_preview.layout = saved_layout
        close_extra_tabs(base_tabs)
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end)

    --- @param path string
    --- @param state agentic.ui.DiffState|nil
    --- @param line string
    --- @param can_open boolean|nil
    local function show_new(path, state, line, can_open)
        DiffPreview.show_diff({
            file_path = path,
            diff = { old = {}, new = { line } },
            state = state,
            get_winid = function(bufnr)
                if can_open == false then
                    return nil
                end
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, bufnr)
                return winid
            end,
        })
    end

    --- @param path string
    --- @param state agentic.ui.DiffState
    --- @param line string
    --- @param tabpage integer|nil
    --- @param can_open boolean|nil
    --- @return integer bufnr
    local function show_existing(path, state, line, tabpage, can_open)
        fs_stat_stub:returns({ type = "file" })
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        if not vim.b[bufnr]._agentic_inline_diff_owner then
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "local x = 1", "" }
            )
        end
        DiffPreview.show_diff({
            file_path = path,
            diff = { old = { "local x = 1" }, new = { line } },
            state = state,
            tabpage = tabpage,
            get_winid = function(target)
                if can_open == false then
                    return nil
                end
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, target)
                return winid
            end,
        })
        return bufnr
    end

    it(
        "gives same-path new-file suggestions distinct owner identities",
        function()
            local path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local first = {}
            --- @type agentic.ui.DiffState
            local second = {}

            show_new(path, first, "first")
            show_new(path, second, "second")

            assert.is_not_nil(first.preview_bufnr)
            assert.is_not_nil(second.preview_bufnr)
            assert.is_not.equal(first.preview_bufnr, second.preview_bufnr)
            assert.is_not.equal(
                vim.api.nvim_buf_get_name(first.preview_bufnr),
                vim.api.nvim_buf_get_name(second.preview_bufnr)
            )
        end
    )

    it("refreshes a new-file suggestion for the same owner", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local state = {}

        show_new(path, state, "first")
        local bufnr = state.preview_bufnr
        assert.is_not_nil(bufnr)
        ---@cast bufnr integer
        show_new(path, state, "second")

        assert.equal(bufnr, state.preview_bufnr)
        assert.equal(
            "second",
            vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
        )
    end)

    it("preserves a same-owner suggestion when refresh cannot open", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local state = {}

        show_new(path, state, "first")
        local bufnr = state.preview_bufnr
        local winid = state.preview_winid
        assert.is_not_nil(bufnr)
        assert.is_not_nil(winid)
        ---@cast bufnr integer

        show_new(path, state, "second", false)

        assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        assert.equal(bufnr, state.preview_bufnr)
        assert.equal(winid, state.preview_winid)
        assert.equal(tostring(state), vim.b[bufnr]._agentic_inline_diff_owner)
        assert.equal(
            "second",
            vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
        )
    end)

    it("deletes a legacy suggestion when refresh cannot open", function()
        local path = vim.fn.tempname() .. ".lua"

        show_new(path, nil, "first")
        local bufnr = vim.fn.bufnr(FileSystem.to_smart_path(path))
        assert.is_not.equal(-1, bufnr)

        show_new(path, nil, "second", false)

        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    end)

    it("deletes a wrong-owner suggestion when refresh cannot open", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local state = {}

        show_new(path, state, "first")
        local bufnr = state.preview_bufnr
        assert.is_not_nil(bufnr)
        ---@cast bufnr integer
        vim.b[bufnr]._agentic_inline_diff_owner = "foreign"
        clear_state_spy = spy_module.on(HunkNavigation, "clear_state")

        show_new(path, state, "second", false)

        local navigation_cleared = clear_state_spy:called_with(bufnr)
        clear_state_spy:revert()
        clear_state_spy = nil
        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
        assert.is_nil(state.preview_bufnr)
        assert.is_nil(state.preview_winid)
        assert.is_true(navigation_cleared)
    end)

    it("deletes a wrong-source suggestion when refresh cannot open", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local state = {}

        show_new(path, state, "first")
        local bufnr = state.preview_bufnr
        assert.is_not_nil(bufnr)
        ---@cast bufnr integer
        vim.b[bufnr]._agentic_suggestion_for = path .. ".foreign"
        clear_state_spy = spy_module.on(HunkNavigation, "clear_state")

        show_new(path, state, "second", false)

        local navigation_cleared = clear_state_spy:called_with(bufnr)
        clear_state_spy:revert()
        clear_state_spy = nil
        assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
        assert.is_nil(state.preview_bufnr)
        assert.is_nil(state.preview_winid)
        assert.is_true(navigation_cleared)
    end)

    it(
        "replaces a different new-file suggestion only after its target opens",
        function()
            local first_path = vim.fn.tempname() .. ".lua"
            local second_path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}

            show_new(first_path, state, "first")
            local first_bufnr = state.preview_bufnr
            assert.is_not_nil(first_bufnr)
            ---@cast first_bufnr integer

            show_new(second_path, state, "second", false)

            assert.equal(first_bufnr, state.preview_bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(first_bufnr))
            assert.equal(
                tostring(state),
                vim.b[first_bufnr]._agentic_inline_diff_owner
            )

            show_new(second_path, state, "second")

            local second_bufnr = state.preview_bufnr
            assert.is_not_nil(second_bufnr)
            ---@cast second_bufnr integer
            assert.is_not.equal(first_bufnr, second_bufnr)
            assert.is_false(vim.api.nvim_buf_is_valid(first_bufnr))
            assert.equal(
                tostring(state),
                vim.b[second_bufnr]._agentic_inline_diff_owner
            )
            assert.equal(
                second_path,
                vim.b[second_bufnr]._agentic_suggestion_for
            )
        end
    )

    it("rejects a second owner for an existing-file inline preview", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local first = {}
        --- @type agentic.ui.DiffState
        local second = {}
        local bufnr = show_existing(path, first, "local x = 2")
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {})

        show_existing(path, second, "local x = 3")

        assert.equal(tostring(first), vim.b[bufnr]._agentic_inline_diff_owner)
        assert.is_nil(second.preview_bufnr)
        assert.same(marks, vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {}))
    end)

    it(
        "refreshes an existing-file inline preview for the same owner",
        function()
            local path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}
            local bufnr = show_existing(path, state, "local x = 2")
            local before = vim.api.nvim_buf_get_extmarks(
                bufnr,
                -1,
                0,
                -1,
                { details = true }
            )

            show_existing(path, state, "local x = 3")

            local after = vim.api.nvim_buf_get_extmarks(
                bufnr,
                -1,
                0,
                -1,
                { details = true }
            )
            assert.equal(bufnr, state.preview_bufnr)
            assert.equal(
                tostring(state),
                vim.b[bufnr]._agentic_inline_diff_owner
            )
            assert.is_not.same(before, after)
        end
    )

    it(
        "retires a different existing-file preview only after its target opens",
        function()
            local first_path = vim.fn.tempname() .. ".lua"
            local second_path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}
            local first_bufnr = show_existing(first_path, state, "local x = 2")
            local namespace =
                vim.api.nvim_create_namespace("agentic_diff_preview")
            local first_marks =
                vim.api.nvim_buf_get_extmarks(first_bufnr, namespace, 0, -1, {})
            assert.is_true(#first_marks > 0)

            show_existing(second_path, state, "local x = 3", nil, false)

            assert.equal(first_bufnr, state.preview_bufnr)
            assert.equal(
                tostring(state),
                vim.b[first_bufnr]._agentic_inline_diff_owner
            )
            assert.is_false(vim.bo[first_bufnr].modifiable)

            local second_bufnr =
                show_existing(second_path, state, "local x = 3")

            assert.equal(second_bufnr, state.preview_bufnr)
            assert.is_nil(vim.b[first_bufnr]._agentic_inline_diff_owner)
            assert.is_nil(vim.b[first_bufnr]._agentic_prev_modifiable)
            assert.is_true(vim.bo[first_bufnr].modifiable)
            assert.same(
                {},
                vim.api.nvim_buf_get_extmarks(first_bufnr, namespace, 0, -1, {})
            )

            local found_navigation = false
            for _, keymap in
                ipairs(vim.api.nvim_buf_get_keymap(first_bufnr, "n"))
            do
                if keymap.lhs == Config.keymaps.diff_preview.next_hunk then
                    found_navigation = true
                end
            end
            assert.is_false(found_navigation)
        end
    )

    it("leaves another owner intact during out-of-order clear", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local first = {}
        --- @type agentic.ui.DiffState
        local second = {}
        local bufnr = show_existing(path, first, "local x = 2")

        DiffPreview.clear_diff(bufnr, false, second)

        assert.equal(bufnr, first.preview_bufnr)
        assert.equal(tostring(first), vim.b[bufnr]._agentic_inline_diff_owner)
        assert.is_false(vim.bo[bufnr].modifiable)
    end)

    it(
        "nil-state clear leaves a state-owned inline preview unchanged",
        function()
            local path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}
            local bufnr = show_existing(path, state, "local x = 2")

            DiffPreview.clear_diff(bufnr, false, nil)

            assert.equal(bufnr, state.preview_bufnr)
            assert.equal(
                tostring(state),
                vim.b[bufnr]._agentic_inline_diff_owner
            )
        end
    )

    it(
        "nil-state clear and cleanup ignore state-qualified suggestions",
        function()
            local path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}
            show_new(path, state, "content")
            local bufnr = state.preview_bufnr
            assert.is_not_nil(bufnr)
            ---@cast bufnr integer

            DiffPreview.clear_diff(path, false, nil)

            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.equal(bufnr, state.preview_bufnr)

            DiffPreview.cleanup_suggestion_buffer(path, nil)

            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
            assert.equal(bufnr, state.preview_bufnr)
        end
    )

    it(
        "does not replace a window repurposed after showing a suggestion",
        function()
            local path = vim.fn.tempname() .. ".lua"
            --- @type agentic.ui.DiffState
            local state = {}
            show_new(path, state, "content")
            local suggestion_bufnr = state.preview_bufnr
            local preview_winid = state.preview_winid
            assert.is_not_nil(suggestion_bufnr)
            assert.is_not_nil(preview_winid)
            ---@cast suggestion_bufnr integer
            ---@cast preview_winid integer
            local replacement_bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(preview_winid, replacement_bufnr)

            DiffPreview.cleanup_suggestion_buffer(path, state)

            assert.equal(
                replacement_bufnr,
                vim.api.nvim_win_get_buf(preview_winid)
            )
            assert.is_false(vim.api.nvim_buf_is_valid(suggestion_bufnr))
            assert.is_nil(state.preview_bufnr)
            assert.is_nil(state.preview_winid)
        end
    )

    it("restricts existing-buffer lookup to the explicit tabpage", function()
        local path = vim.fn.tempname() .. ".lua"
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 1", "" })

        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        local owner_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(owner_win, bufnr)
        vim.cmd("tabnew")
        local foreign_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(foreign_win, bufnr)

        --- @type agentic.ui.DiffState
        local state = {}
        show_existing(path, state, "local x = 2", owner_tab)

        assert.equal(owner_win, state.preview_winid)
        assert.is_not.equal(foreign_win, state.preview_winid)
    end)

    it("keeps unscoped visible-window lookup when tabpage is nil", function()
        local path = vim.fn.tempname() .. ".lua"
        --- @type agentic.ui.DiffState
        local state = {}
        local bufnr = show_existing(path, state, "local x = 2", nil)

        assert.equal(bufnr, state.preview_bufnr)
        assert.is_not_nil(state.preview_winid)
    end)
end)
