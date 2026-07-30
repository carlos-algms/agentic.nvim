local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")

describe("DiffSplitView", function()
    local DiffSplitView = require("agentic.ui.diff_split_view")
    local FileSystem = require("agentic.utils.file_system")

    local test_file_path = "/tmp/test_diff_split_view_fake.lua"
    local test_tabpage
    local read_stub

    --- Split state lives on the owning session's diff state, not the tabpage,
    --- so each case gets a fresh one.
    --- @type agentic.ui.DiffState
    local diff_state

    --- @param lines string[]|nil
    local function stub_file_content(lines)
        read_stub:returns(lines, nil)
    end

    --- @param opts agentic.ui.DiffPreview.ShowOpts
    --- @return boolean success
    local function show_split(opts)
        opts.state = diff_state
        return DiffSplitView.show_split_diff(opts)
    end

    --- `split_state` is keyed by ABSOLUTE path; resolve test literals the same
    --- way production does.
    --- @param path string
    --- @param state agentic.ui.DiffState|nil Defaults to the case's `diff_state`
    --- @return agentic.ui.DiffSplitView.State|nil
    local function get_split(path, state)
        local split_states = (state or diff_state).split_state
        return split_states and split_states[FileSystem.to_absolute_path(path)]
    end

    before_each(function()
        read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
        stub_file_content({ "local x = 1", "print(x)", "" })
        diff_state = {}
        vim.cmd("tabnew")
        test_tabpage = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        read_stub:revert()
        pcall(DiffSplitView.clear_split_diff, diff_state)
        if test_tabpage and vim.api.nvim_tabpage_is_valid(test_tabpage) then
            pcall(vim.api.nvim_tabpage_del, test_tabpage)
        end
    end)

    --- @return number bufnr
    local function setup_and_show_split()
        local bufnr = vim.fn.bufadd(test_file_path)

        show_split({
            file_path = test_file_path,
            diff = { old = { "local x = 1" }, new = { "local x = 2" } },
            get_winid = function()
                return vim.api.nvim_get_current_win()
            end,
        })

        return bufnr
    end

    describe("show_split_diff", function()
        it(
            "should fallback to inline mode for new files (empty old, file does not exist)",
            function()
                stub_file_content(nil)

                local success = show_split({
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

                local success = show_split({
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
                -- loaded so the lightweight existence check succeeds
                local bufnr = vim.fn.bufadd(test_file_path)
                vim.fn.bufload(bufnr)

                local success = show_split({
                    file_path = test_file_path,
                    diff = { old = {}, new = { "local y = 2" } },
                    get_winid = function()
                        return vim.api.nvim_get_current_win()
                    end,
                })

                assert.is_true(success)

                local state = get_split(test_file_path)
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
                local bufnr = setup_and_show_split()
                local state = get_split(test_file_path)

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

            local success = show_split({
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

            local state = get_split(test_file_path)
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

            local success = show_split({
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

            local state = get_split(test_file_path)
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

            local success = show_split({
                file_path = test_file_path,
                diff = {
                    old = { "nonexistent line content" },
                    new = { "replacement" },
                },
                get_winid = get_winid_spy --[[@as function]],
            })

            assert.is_false(success)
            assert.is_nil(diff_state.split_state)
            assert.spy(get_winid_spy).was.called(0)
            get_winid_spy:revert()
        end)

        it("should handle substring fallback for single-line diffs", function()
            local success = show_split({
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

            local state = get_split(test_file_path)
            assert.is_not_nil(state)

            if state then
                local lines =
                    vim.api.nvim_buf_get_lines(state.new_bufnr, 0, -1, false)
                assert.same({ "local x = 2", "print(x)", "" }, lines)
            end
        end)

        it("should replace all matches when replace_all is true", function()
            stub_file_content({ "print(a)", "print(b)", "print(a)", "" })

            local success = show_split({
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

            local state = get_split(test_file_path)
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

                local success = show_split({
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

                local state = get_split(test_file_path)
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

            local first = show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = get_winid,
            })
            assert.is_true(first)

            local state1 = get_split(test_file_path)
            assert.is_not_nil(state1)

            local second = show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                get_winid = get_winid,
            })
            assert.is_true(second)

            local state2 = get_split(test_file_path)
            assert.is_not_nil(state2)

            if state2 then
                assert.equal(bufnr, state2.original_bufnr)
                assert.is_true(vim.api.nvim_buf_is_valid(state2.new_bufnr))
                assert.is_true(vim.api.nvim_win_is_valid(state2.new_winid))

                local lines =
                    vim.api.nvim_buf_get_lines(state2.new_bufnr, 0, -1, false)
                assert.same({ "local x = 3", "print(x)", "" }, lines)
            end

            DiffSplitView.clear_split_diff(diff_state)
            assert.is_nil(diff_state.split_state)
            assert.equal(orig_modifiable, vim.bo[bufnr].modifiable)
        end)

        -- Two sessions on one path each own a `DiffState`, but the scratch
        -- buffer name derives from the path alone. The second call must not
        -- steal or invalidate the first session's split.
        it(
            "gives each session its own split state for the same path",
            function()
                --- @type agentic.ui.DiffState
                local other_state = {}
                local get_winid = function()
                    return vim.api.nvim_get_current_win()
                end
                local diff =
                    { old = { "local x = 1" }, new = { "local x = 2" } }

                assert.is_true(show_split({
                    file_path = test_file_path,
                    diff = diff,
                    get_winid = get_winid,
                }))
                local first = get_split(test_file_path)
                assert.is_not_nil(first)
                ---@cast first agentic.ui.DiffSplitView.State

                assert.is_true(DiffSplitView.show_split_diff({
                    file_path = test_file_path,
                    diff = diff,
                    get_winid = get_winid,
                    state = other_state,
                }))
                local second = get_split(test_file_path, other_state)
                assert.is_not_nil(second)
                ---@cast second agentic.ui.DiffSplitView.State

                assert.is_not.equal(first, second)
                DiffSplitView.clear_split_diff(other_state)
                assert.is_nil(other_state.split_state)
                assert.is_not_nil(diff_state.split_state)

                -- Documented consequence of the shared `<path> (suggestion)`
                -- name: the second call reclaims the first's scratch buffer, so
                -- the surviving state points at a dead buffer.
                assert.is_false(vim.api.nvim_buf_is_valid(first.new_bufnr))
            end
        )

        -- `split_state` is keyed BY PATH. A single slot let a pending edit to a
        -- DIFFERENT file overwrite the first, orphaning its scratch buffer,
        -- window and forced `modifiable = false` beyond `clear_split_diff`.
        it("keeps a split per previewed file and tears down each", function()
            local other_path = "/tmp/test_diff_split_view_fake_other.lua"
            local get_winid = function()
                return vim.api.nvim_get_current_win()
            end

            assert.is_true(show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = get_winid,
            }))
            local first = get_split(test_file_path)
            assert.is_not_nil(first)
            ---@cast first agentic.ui.DiffSplitView.State
            local first_modifiable =
                vim.b[first.original_bufnr]._agentic_prev_modifiable

            assert.is_true(show_split({
                file_path = other_path,
                diff = { old = { "print(x)" }, new = { "print(y)" } },
                get_winid = get_winid,
            }))
            local second = get_split(other_path)
            assert.is_not_nil(second)
            ---@cast second agentic.ui.DiffSplitView.State

            assert.is_not.equal(first.file_path, second.file_path)
            assert.is_not.equal(first.new_bufnr, second.new_bufnr)
            assert.is_not_nil(get_split(test_file_path))

            assert.is_true(
                DiffSplitView.clear_split_diff(diff_state, other_path)
            )
            assert.is_false(vim.api.nvim_buf_is_valid(second.new_bufnr))
            assert.is_nil(get_split(other_path))
            assert.is_not_nil(get_split(test_file_path))
            assert.is_true(vim.api.nvim_buf_is_valid(first.new_bufnr))
            assert.is_true(vim.api.nvim_win_is_valid(first.new_winid))

            assert.is_true(
                DiffSplitView.clear_split_diff(diff_state, test_file_path)
            )
            assert.is_false(vim.api.nvim_buf_is_valid(first.new_bufnr))
            assert.is_false(vim.api.nvim_win_is_valid(first.new_winid))
            assert.equal(
                first_modifiable,
                vim.bo[first.original_bufnr].modifiable
            )
            assert.is_nil(diff_state.split_state)
        end)
    end)

    describe("clear_split_diff", function()
        it("should restore original buffer state and clear state", function()
            local bufnr = vim.fn.bufadd(test_file_path)

            local orig_modifiable = vim.bo[bufnr].modifiable
            local orig_modified = vim.bo[bufnr].modified

            show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = function()
                    return vim.api.nvim_get_current_win()
                end,
            })

            DiffSplitView.clear_split_diff(diff_state)

            assert.equal(orig_modifiable, vim.bo[bufnr].modifiable)
            assert.equal(orig_modified, vim.bo[bufnr].modified)
            assert.is_nil(diff_state.split_state)
        end)

        it(
            "should handle cleanup when scratch window already closed",
            function()
                setup_and_show_split()
                local state = get_split(test_file_path)

                assert.is_not_nil(state)
                if state then
                    pcall(vim.api.nvim_win_close, state.new_winid, true)
                end

                assert.has_no_errors(function()
                    DiffSplitView.clear_split_diff(diff_state)
                end)
                assert.is_nil(diff_state.split_state)
            end
        )

        -- Closing the window explicitly makes `nvim_win_is_valid` false: the
        -- easy case. On 0.11.x a `tabclose` leaves both handles stale-VALID and
        -- `nvim_win_call` on one segfaults. `clear_split_diff` runs from
        -- tool-call teardown, possibly after the user closed the tab, so the
        -- tabpage must be consulted too.
        it("skips stale-valid handles whose tabpage is gone", function()
            setup_and_show_split()
            local state = get_split(test_file_path)
            assert.is_not_nil(state)
            ---@cast state agentic.ui.DiffSplitView.State

            local dead_tab = vim.api.nvim_win_get_tabpage(state.new_winid)

            -- Dead tabpage, both window handles still valid: the exact
            -- post-`tabclose` state 0.11.x leaves behind.
            local real_tab_is_valid = vim.api.nvim_tabpage_is_valid
            local tab_valid_stub =
                spy_module.stub(vim.api, "nvim_tabpage_is_valid")
            tab_valid_stub:invokes(function(tab)
                return tab ~= dead_tab and real_tab_is_valid(tab)
            end)
            local win_call_stub = spy_module.stub(vim.api, "nvim_win_call")
            local close_stub = spy_module.stub(vim.api, "nvim_win_close")

            assert.is_true(vim.api.nvim_win_is_valid(state.original_winid))
            assert.is_true(vim.api.nvim_win_is_valid(state.new_winid))

            DiffSplitView.clear_split_diff(diff_state)

            tab_valid_stub:revert()
            win_call_stub:revert()
            close_stub:revert()

            assert.equal(0, win_call_stub.call_count)
            assert.equal(0, close_stub.call_count)
            assert.is_nil(diff_state.split_state)
        end)
    end)
end)
