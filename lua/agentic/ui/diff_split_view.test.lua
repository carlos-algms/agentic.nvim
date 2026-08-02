local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")

describe("DiffSplitView", function()
    local DiffSplitView = require("agentic.ui.diff_split_view")
    local FileSystem = require("agentic.utils.file_system")
    local BufHelpers = require("agentic.utils.buf_helpers")
    local DiffPreview = require("agentic.ui.diff_preview")

    local test_file_path = "/tmp/test_diff_split_view_fake.lua"
    local test_tabpage
    local read_stub
    local base_tabs
    local base_bufs
    local owner_states
    --- @type agentic.ui.DiffState
    local diff_state

    --- @return agentic.ui.DiffState state
    local function new_diff_state()
        --- @type agentic.ui.DiffState
        local state = {}
        owner_states[#owner_states + 1] = state
        return state
    end

    --- @param opts agentic.ui.DiffPreview.ShowOpts
    --- @return boolean success
    local function show_split(opts)
        opts.state = diff_state
        return DiffSplitView.show_split_diff(opts)
    end

    --- @param lines string[]|nil
    local function stub_file_content(lines)
        read_stub:returns(lines, nil)
    end

    before_each(function()
        base_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tabpage] = true
        end
        base_bufs = {}
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            base_bufs[bufnr] = true
        end
        owner_states = {}
        read_stub = spy_module.stub(FileSystem, "read_from_buffer_or_disk")
        stub_file_content({ "local x = 1", "print(x)", "" })
        diff_state = new_diff_state()
        vim.cmd("tabnew")
        test_tabpage = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        for _, owner_state in ipairs(owner_states) do
            pcall(DiffSplitView.clear_split_diff, owner_state)
        end
        read_stub:revert()
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tabs[tabpage] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
        local extra_bufs = 0
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if not base_bufs[bufnr] then
                extra_bufs = extra_bufs + 1
            end
        end
        assert.equal(0, extra_bufs)
    end)

    --- @return number bufnr
    --- @return number tabpage
    local function setup_and_show_split()
        local bufnr = vim.fn.bufadd(test_file_path)

        show_split({
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
                -- Load the buffer so the lightweight existence check succeeds
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

                local state = DiffSplitView.find_split_state(diff_state)
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
                local state = DiffSplitView.find_split_state(diff_state)

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

            local state = DiffSplitView.find_split_state(diff_state)
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

            local state = DiffSplitView.find_split_state(diff_state)
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
            assert.is_nil(DiffSplitView.find_split_state(diff_state))
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

            local state = DiffSplitView.find_split_state(diff_state)
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

            local state = DiffSplitView.find_split_state(diff_state)
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

                local state = DiffSplitView.find_split_state(diff_state)
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

            local state1 = DiffSplitView.find_split_state(diff_state)
            assert.is_not_nil(state1)

            local second = show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                get_winid = get_winid,
            })
            assert.is_true(second)

            local state2 = DiffSplitView.find_split_state(diff_state)
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
            assert.is_nil(DiffSplitView.find_split_state(diff_state))
            assert.equal(orig_modifiable, vim.bo[bufnr].modifiable)
        end)

        it("stores two split paths under one owner", function()
            --- @type agentic.ui.DiffState
            local owner_state = new_diff_state()
            local first_path = test_file_path .. ".first"
            local second_path = test_file_path .. ".second"
            local get_winid = function(bufnr)
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, bufnr)
                return winid
            end

            local first = DiffSplitView.show_split_diff({
                file_path = first_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                state = owner_state,
                get_winid = get_winid,
            })
            local second = DiffSplitView.show_split_diff({
                file_path = second_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                state = owner_state,
                get_winid = get_winid,
            })

            assert.is_true(first)
            assert.is_true(second)
            assert.is_not_nil(owner_state.split_state)
            assert.is_not_nil(owner_state.split_state[first_path])
            assert.is_not_nil(owner_state.split_state[second_path])
        end)

        it("selects the owned split containing the current buffer", function()
            local current = vim.api.nvim_get_current_buf()
            local other = vim.api.nvim_create_buf(false, true)
            local state = {
                split_state = {
                    first = {
                        original_bufnr = other,
                        new_bufnr = other,
                    },
                    second = {
                        original_bufnr = current,
                        new_bufnr = current,
                    },
                },
            }

            local selected = DiffSplitView.find_split_state(state)
            --- @cast selected -nil

            assert.equal(current, selected.original_bufnr)
            pcall(vim.api.nvim_buf_delete, other, { force = true })
        end)

        it("falls back to any split owned by the supplied state", function()
            local state = {
                split_state = {
                    only = {
                        original_bufnr = -1,
                        new_bufnr = -2,
                    },
                },
            }

            assert.is_not_nil(DiffSplitView.find_split_state(state))
        end)

        it("returns nil when the supplied state owns no split", function()
            assert.is_nil(DiffSplitView.find_split_state({}))
        end)

        it("clears only the split matching a requested buffer", function()
            local first_path = test_file_path .. ".first"
            local second_path = test_file_path .. ".second"
            local get_winid = function(bufnr)
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, bufnr)
                return winid
            end
            show_split({
                file_path = first_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = get_winid,
            })
            show_split({
                file_path = second_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                get_winid = get_winid,
            })
            local first = diff_state.split_state[first_path]

            DiffPreview.clear_diff(first.original_bufnr, false, diff_state)

            assert.is_nil(diff_state.split_state[first_path])
            assert.is_not_nil(diff_state.split_state[second_path])
        end)

        it("isolates same-path scratch buffers for two owners", function()
            --- @type agentic.ui.DiffState
            local first_state = new_diff_state()
            --- @type agentic.ui.DiffState
            local second_state = new_diff_state()
            local get_winid = function(bufnr)
                local winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(winid, bufnr)
                return winid
            end
            local opts = {
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                get_winid = get_winid,
                state = first_state,
            }

            assert.is_true(DiffSplitView.show_split_diff(opts))
            opts.state = second_state
            assert.is_true(DiffSplitView.show_split_diff(opts))

            local first = DiffSplitView.find_split_state(first_state)
            local second = DiffSplitView.find_split_state(second_state)
            assert.is_not_nil(first)
            assert.is_not_nil(second)
            ---@cast first agentic.ui.DiffSplitView.State
            ---@cast second agentic.ui.DiffSplitView.State
            assert.is_not.equal(first.new_bufnr, second.new_bufnr)
            assert.is_true(vim.api.nvim_buf_is_valid(first.new_bufnr))
            assert.is_true(vim.api.nvim_buf_is_valid(second.new_bufnr))
        end)

        it(
            "restores the original buffer after the final owner clears",
            function()
                local bufnr = vim.fn.bufadd(test_file_path)
                local original_modifiable = vim.bo[bufnr].modifiable
                --- @type agentic.ui.DiffState
                local first_state = new_diff_state()
                --- @type agentic.ui.DiffState
                local second_state = new_diff_state()
                local function open_for(state)
                    return DiffSplitView.show_split_diff({
                        file_path = test_file_path,
                        diff = {
                            old = { "local x = 1" },
                            new = { "local x = 2" },
                        },
                        state = state,
                        get_winid = function(target)
                            local winid = vim.api.nvim_get_current_win()
                            vim.api.nvim_win_set_buf(winid, target)
                            return winid
                        end,
                    })
                end

                assert.is_true(open_for(first_state))
                assert.is_true(open_for(second_state))
                assert.is_true(DiffSplitView.clear_split_diff(first_state))
                assert.is_false(vim.bo[bufnr].modifiable)
                assert.is_true(DiffSplitView.clear_split_diff(second_state))
                assert.equal(original_modifiable, vim.bo[bufnr].modifiable)
            end
        )

        it("restricts split lookup to the explicit tabpage", function()
            local bufnr = vim.fn.bufadd(test_file_path)
            vim.fn.bufload(bufnr)
            local owner_tab = vim.api.nvim_get_current_tabpage()
            local owner_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(owner_win, bufnr)

            vim.cmd("tabnew")
            local foreign_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(foreign_win, bufnr)
            --- @type agentic.ui.DiffState
            local state = new_diff_state()

            DiffSplitView.show_split_diff({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 2" } },
                state = state,
                tabpage = owner_tab,
                get_winid = function()
                    return foreign_win
                end,
            })

            local split = DiffSplitView.find_split_state(state)
            assert.is_not_nil(split)
            ---@cast split agentic.ui.DiffSplitView.State
            assert.equal(owner_win, split.original_winid)
        end)

        it(
            "skips scheduled navigation when the target window is unusable",
            function()
                local scheduled
                local schedule_stub = spy_module.stub(vim, "schedule")
                schedule_stub:invokes(function(callback)
                    scheduled = callback
                end)
                setup_and_show_split()
                local split = DiffSplitView.find_split_state(diff_state)
                assert.is_not_nil(split)
                ---@cast split agentic.ui.DiffSplitView.State
                local usable_stub = spy_module.stub(BufHelpers, "is_win_usable")
                usable_stub:returns(false)
                local win_call_stub = spy_module.stub(vim.api, "nvim_win_call")

                scheduled()

                local usable_called =
                    usable_stub:called_with(split.original_winid)
                local win_call_count = win_call_stub.call_count
                win_call_stub:revert()
                usable_stub:revert()
                schedule_stub:revert()
                assert.is_true(usable_called)
                assert.equal(0, win_call_count)
            end
        )

        it(
            "skips scheduled navigation when the original window is repurposed",
            function()
                local scheduled
                local schedule_stub = spy_module.stub(vim, "schedule")
                schedule_stub:invokes(function(callback)
                    scheduled = callback
                end)
                setup_and_show_split()
                local split = DiffSplitView.find_split_state(diff_state)
                assert.is_not_nil(split)
                ---@cast split agentic.ui.DiffSplitView.State
                local replacement_bufnr = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_win_set_buf(
                    split.original_winid,
                    replacement_bufnr
                )
                local win_call_stub = spy_module.stub(vim.api, "nvim_win_call")

                scheduled()

                local win_call_count = win_call_stub.call_count
                win_call_stub:revert()
                schedule_stub:revert()
                assert.equal(0, win_call_count)
            end
        )

        it("does not close an unusable stale suggestion window", function()
            setup_and_show_split()
            local usable_stub = spy_module.stub(BufHelpers, "is_win_usable")
            usable_stub:returns(false)
            local close_stub = spy_module.stub(vim.api, "nvim_win_close")

            show_split({
                file_path = test_file_path,
                diff = { old = { "local x = 1" }, new = { "local x = 3" } },
                get_winid = function(bufnr)
                    local winid = vim.api.nvim_get_current_win()
                    vim.api.nvim_win_set_buf(winid, bufnr)
                    return winid
                end,
            })

            local usable_count = usable_stub.call_count
            local close_count = close_stub.call_count
            close_stub:revert()
            usable_stub:revert()
            assert.is_true(usable_count > 0)
            assert.equal(0, close_count)
        end)
    end)

    describe("clear_split_diff", function()
        it("reports whether it tore down a matching split", function()
            setup_and_show_split()

            assert.is_false(
                DiffSplitView.clear_split_diff(diff_state, "/tmp/missing.lua")
            )
            assert.is_true(
                DiffSplitView.clear_split_diff(diff_state, test_file_path)
            )
            assert.is_false(
                DiffSplitView.clear_split_diff(diff_state, test_file_path)
            )
        end)
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
            assert.is_nil(DiffSplitView.find_split_state(diff_state))
        end)

        it(
            "should handle cleanup when scratch window already closed",
            function()
                setup_and_show_split()
                local state = DiffSplitView.find_split_state(diff_state)

                assert.is_not_nil(state)
                if state then
                    pcall(vim.api.nvim_win_close, state.new_winid, true)
                end

                assert.has_no_errors(function()
                    DiffSplitView.clear_split_diff(diff_state)
                end)
                assert.is_nil(DiffSplitView.find_split_state(diff_state))
            end
        )

        it("skips stale-valid handles whose tabpage is gone", function()
            setup_and_show_split()
            local usable_stub = spy_module.stub(BufHelpers, "is_win_usable")
            usable_stub:returns(false)
            local win_call_stub = spy_module.stub(vim.api, "nvim_win_call")
            local close_stub = spy_module.stub(vim.api, "nvim_win_close")

            DiffSplitView.clear_split_diff(diff_state)

            local usable_count = usable_stub.call_count
            local win_call_count = win_call_stub.call_count
            local close_count = close_stub.call_count
            close_stub:revert()
            win_call_stub:revert()
            usable_stub:revert()
            assert.is_true(usable_count > 0)
            assert.equal(0, win_call_count)
            assert.equal(0, close_count)
        end)
    end)
end)
