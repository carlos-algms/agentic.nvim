local assert = require("tests.helpers.assert")
local BufHelpers = require("agentic.utils.buf_helpers")
local HunkNavigation = require("agentic.ui.hunk_navigation")
local Theme = require("agentic.theme")

--- @param bufnr number
--- @return integer[]
local function get_hunk_anchors(bufnr)
    ---@diagnostic disable-next-line: invisible
    return HunkNavigation._get_hunk_anchors(bufnr)
end

--- @param bufnr number
--- @param ns number
--- @param line number
local function add_hunk(bufnr, ns, line)
    local line_content =
        vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
    vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
        end_row = line,
        end_col = #line_content,
        hl_group = Theme.HL_GROUPS.DIFF_DELETE,
    })
end

--- @param bufnr number
--- @param key string
--- @return table
local function get_keymap_in_buf(bufnr, key)
    return vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(key, "n", false, true)
    end)
end

--- @param map table|nil
--- @return boolean
local function is_buffer_local(map)
    return map ~= nil and map.buffer == 1
end

local test_ns = HunkNavigation.NS_DIFF

describe("hunk_navigation", function()
    local test_bufnr

    before_each(function()
        test_bufnr = vim.api.nvim_create_buf(false, true)
        local lines = {}
        for i = 1, 60 do
            table.insert(lines, "line " .. i)
        end
        vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, lines)
    end)

    after_each(function()
        HunkNavigation.clear_state(test_bufnr)
        pcall(vim.api.nvim_buf_delete, test_bufnr, { force = true })
    end)

    describe("_get_hunk_anchors", function()
        it("sorts anchors and ignores non-highlight extmarks", function()
            add_hunk(test_bufnr, test_ns, 2)
            add_hunk(test_bufnr, test_ns, 0)
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 3, 0, {
                virt_text = { { "not a hunk", "Comment" } },
            })
            add_hunk(test_bufnr, test_ns, 4)

            local anchors = get_hunk_anchors(test_bufnr)

            assert.equal(#anchors, 3)
            assert.equal(anchors[1], 0)
            assert.equal(anchors[2], 2)
            assert.equal(anchors[3], 4)
        end)

        it("caches results on subsequent calls", function()
            add_hunk(test_bufnr, test_ns, 1)

            local anchors1 = get_hunk_anchors(test_bufnr)
            local anchors2 = get_hunk_anchors(test_bufnr)

            assert.equal(anchors1, anchors2)
        end)

        it("deduplicates multiple highlights on same line", function()
            local line =
                vim.api.nvim_buf_get_lines(test_bufnr, 10, 11, false)[1]
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 10, 0, {
                end_row = 10,
                end_col = math.min(5, #line),
                hl_group = Theme.HL_GROUPS.DIFF_DELETE,
            })
            vim.api.nvim_buf_set_extmark(
                test_bufnr,
                test_ns,
                10,
                math.min(6, #line),
                {
                    end_row = 10,
                    end_col = #line,
                    hl_group = Theme.HL_GROUPS.DIFF_DELETE_WORD,
                }
            )

            local anchors = get_hunk_anchors(test_bufnr)

            assert.equal(#anchors, 1)
            assert.equal(anchors[1], 10)
        end)

        it("groups consecutive deleted lines (one anchor per group)", function()
            add_hunk(test_bufnr, test_ns, 10)
            add_hunk(test_bufnr, test_ns, 11)
            add_hunk(test_bufnr, test_ns, 12)
            add_hunk(test_bufnr, test_ns, 20)
            add_hunk(test_bufnr, test_ns, 21)
            add_hunk(test_bufnr, test_ns, 30)

            local anchors = get_hunk_anchors(test_bufnr)

            assert.equal(#anchors, 3)
            assert.equal(anchors[1], 10)
            assert.equal(anchors[2], 20)
            assert.equal(anchors[3], 30)
        end)

        it("falls back to virtual line anchor for pure insertions", function()
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 5, 0, {
                virt_lines = { { { "inserted line", "Comment" } } },
            })
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 15, 0, {
                virt_lines = { { { "inserted line", "Comment" } } },
            })

            local anchors = get_hunk_anchors(test_bufnr)

            assert.equal(#anchors, 2)
            assert.equal(anchors[1], 5)
            assert.equal(anchors[2], 15)
        end)

        it("falls back to line 0 when no extmarks exist", function()
            local anchors = get_hunk_anchors(test_bufnr)

            assert.equal(#anchors, 1)
            assert.equal(anchors[1], 0)
        end)
    end)

    describe("navigation", function()
        local winid

        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
            winid = vim.api.nvim_get_current_win()
            HunkNavigation.setup_keymaps(test_bufnr)
        end)

        after_each(function()
            HunkNavigation.clear_state(test_bufnr)
        end)

        it("navigates through hunks with bidirectional wrapping", function()
            add_hunk(test_bufnr, test_ns, 1)
            add_hunk(test_bufnr, test_ns, 3)

            HunkNavigation.navigate_next(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            HunkNavigation.navigate_next(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

            HunkNavigation.navigate_next(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            HunkNavigation.navigate_prev(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

            HunkNavigation.navigate_prev(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)
        end)

        it("wraps to itself with single hunk", function()
            add_hunk(test_bufnr, test_ns, 1)

            HunkNavigation.navigate_next(test_bufnr)
            local pos1 = vim.api.nvim_win_get_cursor(winid)[1]

            HunkNavigation.navigate_next(test_bufnr)
            local pos2 = vim.api.nvim_win_get_cursor(winid)[1]

            assert.equal(pos1, pos2)
        end)

        it("positions cursor at column 0", function()
            add_hunk(test_bufnr, test_ns, 10)

            HunkNavigation.navigate_next(test_bufnr)

            local cursor = vim.api.nvim_win_get_cursor(winid)
            assert.equal(cursor[1], 11)
            assert.equal(cursor[2], 0)
        end)

        it(
            "navigates prev to closest hunk when cursor is between hunks",
            function()
                add_hunk(test_bufnr, test_ns, 1)
                add_hunk(test_bufnr, test_ns, 5)

                vim.api.nvim_win_set_cursor(winid, { 8, 0 })

                HunkNavigation.navigate_prev(test_bufnr)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 6)

                HunkNavigation.navigate_prev(test_bufnr)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

                HunkNavigation.navigate_prev(test_bufnr)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 6)
            end
        )

        it("navigates prev when cursor is exactly on hunk anchor", function()
            add_hunk(test_bufnr, test_ns, 1)
            add_hunk(test_bufnr, test_ns, 5)

            vim.api.nvim_win_set_cursor(winid, { 6, 0 })

            HunkNavigation.navigate_prev(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            HunkNavigation.navigate_prev(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 6)
        end)
    end)

    describe("navigation with center_on_navigate_hunks config", function()
        local Config
        local original_center_setting
        local winid

        before_each(function()
            Config = require("agentic.config")
            original_center_setting =
                Config.diff_preview.center_on_navigate_hunks
            vim.cmd("buffer " .. test_bufnr)
            winid = vim.api.nvim_get_current_win()
            HunkNavigation.setup_keymaps(test_bufnr)
        end)

        after_each(function()
            Config.diff_preview.center_on_navigate_hunks =
                original_center_setting
            HunkNavigation.clear_state(test_bufnr)
        end)

        it("navigates when center_on_navigate_hunks = false", function()
            Config.diff_preview.center_on_navigate_hunks = false

            add_hunk(test_bufnr, test_ns, 1)
            add_hunk(test_bufnr, test_ns, 3)

            vim.api.nvim_win_set_cursor(winid, { 1, 0 })

            HunkNavigation.navigate_next(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            HunkNavigation.navigate_next(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

            HunkNavigation.navigate_prev(test_bufnr)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)
        end)
    end)

    describe("get_scroll_cmd", function()
        local Config
        local original_center_setting
        local winid

        before_each(function()
            Config = require("agentic.config")
            original_center_setting =
                Config.diff_preview.center_on_navigate_hunks
            vim.cmd("buffer " .. test_bufnr)
            winid = vim.api.nvim_get_current_win()
        end)

        after_each(function()
            Config.diff_preview.center_on_navigate_hunks =
                original_center_setting
        end)

        it(
            "returns empty string when centering disabled or no extmarks",
            function()
                Config.diff_preview.center_on_navigate_hunks = false
                add_hunk(test_bufnr, test_ns, 1)
                assert.equal(
                    HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1),
                    ""
                )

                Config.diff_preview.center_on_navigate_hunks = true
                assert.equal(
                    HunkNavigation.get_scroll_cmd(test_bufnr, winid, 5),
                    ""
                )
            end
        )

        it("returns 'zz' for small hunks, 'zt' for large hunks", function()
            Config.diff_preview.center_on_navigate_hunks = true

            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 1, 0, {
                virt_lines = { { { "small hunk", "Comment" } } },
            })
            assert.equal(
                HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1),
                "zz"
            )

            local win_height = vim.api.nvim_win_get_height(winid)
            local large_virt_lines = {}
            for i = 1, math.floor(win_height / 2) + 2 do
                table.insert(large_virt_lines, { { "line " .. i, "Comment" } })
            end
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 2, 0, {
                virt_lines = large_virt_lines,
            })
            assert.equal(
                HunkNavigation.get_scroll_cmd(test_bufnr, winid, 2),
                "zt"
            )
        end)
    end)

    describe("keymap management", function()
        local Config
        local original_keymaps

        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
            Config = require("agentic.config")
            original_keymaps = vim.deepcopy(Config.keymaps.diff_preview)
            Config.keymaps.diff_preview.next_hunk = "<leader>hn"
            Config.keymaps.diff_preview.prev_hunk = "<leader>hp"
        end)

        after_each(function()
            Config.keymaps.diff_preview = original_keymaps
            pcall(vim.keymap.del, "n", "<leader>hn")
            pcall(vim.keymap.del, "n", "<leader>hp")
        end)

        it("does not save global keymaps", function()
            vim.keymap.set("n", "<leader>hn", ":echo 'global'<CR>")

            local global_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_not_nil(global_map)
            assert.is_false(is_buffer_local(global_map))

            HunkNavigation.setup_keymaps(test_bufnr)

            local during_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_true(is_buffer_local(during_map))

            HunkNavigation.restore_keymaps(test_bufnr)

            local after_restore = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_false(is_buffer_local(after_restore))
        end)

        it("saves and restores buffer-local keymaps only", function()
            vim.keymap.set(
                "n",
                "<leader>hn",
                ":echo 'original'<CR>",
                { buffer = test_bufnr }
            )

            local before_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_not_nil(before_map)
            assert.is_true(is_buffer_local(before_map))
            local original_rhs = before_map.rhs

            HunkNavigation.setup_keymaps(test_bufnr)

            local next_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            local prev_map = get_keymap_in_buf(test_bufnr, "<leader>hp")
            assert.is_not_nil(next_map)
            assert.is_not_nil(prev_map)
            assert.is_true(is_buffer_local(next_map))
            assert.is_true(is_buffer_local(prev_map))

            HunkNavigation.restore_keymaps(test_bufnr)

            local after_next = get_keymap_in_buf(test_bufnr, "<leader>hn")
            local after_prev = get_keymap_in_buf(test_bufnr, "<leader>hp")

            -- Unconditional: guarding behind `next(after_next) ~= nil` lets a
            -- silently dropped user mapping pass.
            assert.is_true(is_buffer_local(after_next))
            assert.equal(after_next.rhs, original_rhs)
            assert.equal(next(after_prev), nil)
        end)

        it("clears the anchors cache after restore", function()
            HunkNavigation.setup_keymaps(test_bufnr)
            add_hunk(test_bufnr, test_ns, 1)
            local cached = get_hunk_anchors(test_bufnr)
            assert.equal(cached[1], 1)

            HunkNavigation.restore_keymaps(test_bufnr)

            -- A retained cache hands back the line-1 anchor above; only a
            -- cleared one re-reads the extmarks and sees the new line.
            vim.api.nvim_buf_clear_namespace(test_bufnr, test_ns, 0, -1)
            add_hunk(test_bufnr, test_ns, 20)

            local anchors = get_hunk_anchors(test_bufnr)
            assert.equal(#anchors, 1)
            assert.equal(anchors[1], 20)
        end)
    end)
end)

describe("hunk_navigation split mode", function()
    local Config = require("agentic.config")

    local test_bufnr
    local saved_layout
    local base_tabs

    before_each(function()
        base_tabs = #vim.api.nvim_list_tabpages()
        saved_layout = Config.diff_preview.layout
        Config.diff_preview.layout = "split"

        test_bufnr = vim.api.nvim_create_buf(false, true)
        local lines = {}
        for i = 1, 60 do
            lines[#lines + 1] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, lines)
    end)

    after_each(function()
        Config.diff_preview.layout = saved_layout
        HunkNavigation.clear_state(test_bufnr)

        while #vim.api.nvim_list_tabpages() > base_tabs do
            local ok = pcall(function()
                vim.cmd("tabclose!")
            end)
            if not ok then
                break
            end
        end

        pcall(vim.api.nvim_buf_delete, test_bufnr, { force = true })
    end)

    it("navigates the split's own window, not another tab's", function()
        -- Same buffer in two tabs. Only `split_state.original_winid` says which
        -- window carries the diff; without it the lookup takes tabpage order,
        -- hits a window not in diff mode, and reports "no more hunks" while the
        -- real diff sits untouched.
        vim.cmd("tabnew")
        local foreign_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(foreign_win, test_bufnr)
        vim.api.nvim_win_set_cursor(foreign_win, { 1, 0 })

        vim.cmd("tabnew")
        local split_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(split_win, test_bufnr)
        vim.api.nvim_win_set_cursor(split_win, { 1, 0 })

        -- Identical except line 30, so `]c` from line 1 has somewhere to go.
        local scratch = vim.api.nvim_create_buf(false, true)
        local scratch_lines =
            vim.api.nvim_buf_get_lines(test_bufnr, 0, -1, false)
        scratch_lines[30] = "changed line 30"
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, scratch_lines)
        local scratch_win = vim.api.nvim_open_win(scratch, false, {
            split = "right",
            win = split_win,
        })

        vim.api.nvim_win_call(split_win, function()
            vim.cmd("diffthis")
        end)
        vim.api.nvim_win_call(scratch_win, function()
            vim.cmd("diffthis")
        end)

        -- Keyed by absolute path, matching `DiffSplitView.open_split_view`. A
        -- single unkeyed object made `split_state.original_winid` nil while the
        -- map stayed truthy: split branch taken, window picked by tabpage order.
        --- @type agentic.ui.DiffState
        local diff_state = {
            split_state = {
                ["/tmp/split_nav.lua"] = {
                    original_winid = split_win,
                    original_bufnr = test_bufnr,
                    new_winid = scratch_win,
                    new_bufnr = scratch,
                    file_path = "/tmp/split_nav.lua",
                },
            },
        }

        HunkNavigation.navigate_next(test_bufnr, diff_state)

        -- `]c` moved the split's window off line 1; the foreign tab's window is
        -- untouched.
        assert.is_true(vim.api.nvim_win_get_cursor(split_win)[1] > 1)
        assert.equal(1, vim.api.nvim_win_get_cursor(foreign_win)[1])

        pcall(vim.api.nvim_win_close, scratch_win, true)
        pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    end)

    it(
        "targets the split matching the bufnr, not an arbitrary entry",
        function()
            -- Two pending edits to DIFFERENT files, so `split_state` holds two
            -- entries. `navigate_hunk` gets one bufnr explicitly and must resolve
            -- that file's split. Preferring the CURRENT buffer drives the other
            -- file's window; an arbitrary entry is a coin flip on `pairs` order.
            --- @param label string
            --- @return number bufnr
            --- @return number original_winid
            --- @return number scratch_winid
            --- @return number scratch_bufnr
            local function open_split(label)
                local bufnr = vim.api.nvim_create_buf(false, true)
                local lines = {}
                for i = 1, 60 do
                    lines[#lines + 1] = label .. " line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                vim.cmd("tabnew")
                local original_winid = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(original_winid, bufnr)
                vim.api.nvim_win_set_cursor(original_winid, { 1, 0 })

                local scratch = vim.api.nvim_create_buf(false, true)
                local scratch_lines = vim.deepcopy(lines)
                scratch_lines[30] = label .. " changed line 30"
                vim.api.nvim_buf_set_lines(scratch, 0, -1, false, scratch_lines)
                local scratch_winid = vim.api.nvim_open_win(scratch, false, {
                    split = "right",
                    win = original_winid,
                })

                vim.api.nvim_win_call(original_winid, function()
                    vim.cmd("diffthis")
                end)
                vim.api.nvim_win_call(scratch_winid, function()
                    vim.cmd("diffthis")
                end)

                return bufnr, original_winid, scratch_winid, scratch
            end

            local buf_a, win_a, scratch_win_a, scratch_a = open_split("alpha")
            local buf_b, win_b, scratch_win_b, scratch_b = open_split("beta")

            --- @type agentic.ui.DiffState
            local diff_state = {
                split_state = {
                    ["/tmp/alpha.lua"] = {
                        original_winid = win_a,
                        original_bufnr = buf_a,
                        new_winid = scratch_win_a,
                        new_bufnr = scratch_a,
                        file_path = "/tmp/alpha.lua",
                    },
                    ["/tmp/beta.lua"] = {
                        original_winid = win_b,
                        original_bufnr = buf_b,
                        new_winid = scratch_win_b,
                        new_bufnr = scratch_b,
                        file_path = "/tmp/beta.lua",
                    },
                },
            }

            -- Cursor on beta while navigating alpha, so a current-buffer
            -- preference resolves beta's entry, not alpha's.
            vim.api.nvim_set_current_win(win_b)

            HunkNavigation.navigate_next(buf_a, diff_state)

            assert.is_true(vim.api.nvim_win_get_cursor(win_a)[1] > 1)
            assert.equal(1, vim.api.nvim_win_get_cursor(win_b)[1])

            -- A THIRD buffer with no entry. Resolving by bufnr yields nil and
            -- takes the inline path. An arbitrary entry (or the raw map) keeps
            -- the `layout == "split"` branch live and runs `]c` in a non-diff
            -- window, so the extmark anchor is never reached.
            local buf_c = vim.api.nvim_create_buf(false, true)
            local lines_c = {}
            for i = 1, 60 do
                lines_c[#lines_c + 1] = "gamma line " .. i
            end
            vim.api.nvim_buf_set_lines(buf_c, 0, -1, false, lines_c)

            vim.cmd("tabnew")
            local win_c = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win_c, buf_c)
            vim.api.nvim_win_set_cursor(win_c, { 1, 0 })
            add_hunk(buf_c, test_ns, 10)

            HunkNavigation.navigate_next(buf_c, diff_state)

            assert.equal(11, vim.api.nvim_win_get_cursor(win_c)[1])

            for _, winid in ipairs({ scratch_win_a, scratch_win_b }) do
                pcall(vim.api.nvim_win_close, winid, true)
            end
            for _, bufnr in ipairs({ scratch_a, scratch_b, buf_a, buf_b, buf_c }) do
                HunkNavigation.clear_state(bufnr)
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    )

    it("falls back to any visible window without split state", function()
        vim.cmd("tabnew")
        local only_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(only_win, test_bufnr)
        vim.api.nvim_win_set_cursor(only_win, { 1, 0 })

        add_hunk(test_bufnr, test_ns, 10)

        HunkNavigation.navigate_next(test_bufnr, nil)

        assert.equal(11, vim.api.nvim_win_get_cursor(only_win)[1])
    end)

    it("does not fall back into another session's window", function()
        -- Two sessions diffing the same file. Session one's painted window is
        -- closed, so the `find_visible_win` fallback fires. Landing on session
        -- two's window drives `]c` against someone else's diff, or a non-diff
        -- window that raises E99.
        vim.cmd("tabnew")
        local foreign_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(foreign_win, test_bufnr)
        vim.api.nvim_win_set_cursor(foreign_win, { 1, 0 })

        vim.cmd("tabnew")
        local owner_tab = vim.api.nvim_get_current_tabpage()
        -- Second window in the owner's tab, so closing the painted one leaves
        -- the tabpage (and the scope) alive.
        vim.cmd("split")
        local owner_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(owner_win, test_bufnr)

        add_hunk(test_bufnr, test_ns, 10)

        --- @type agentic.ui.DiffState
        local diff_state = {
            preview_bufnr = test_bufnr,
            preview_winid = owner_win,
        }

        -- Stale owner: the painted window is gone, its tabpage is not.
        vim.api.nvim_win_close(owner_win, true)
        assert.is_true(vim.api.nvim_tabpage_is_valid(owner_tab))

        HunkNavigation.navigate_next(test_bufnr, diff_state)

        assert.equal(1, vim.api.nvim_win_get_cursor(foreign_win)[1])
    end)

    it("restores each session's keymaps independently", function()
        -- Buffer-local keymaps: a second session on the same buffer replaces the
        -- first's `]c`/`[c`. Clearing out of order (session one last) must not
        -- strip the mapping session two still needs.
        local keymaps = Config.keymaps.diff_preview

        vim.cmd("tabnew")
        local win_one = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win_one, test_bufnr)

        vim.cmd("tabnew")
        local win_two = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win_two, test_bufnr)

        --- @type agentic.ui.DiffState
        local state_one =
            { preview_bufnr = test_bufnr, preview_winid = win_one }
        --- @type agentic.ui.DiffState
        local state_two =
            { preview_bufnr = test_bufnr, preview_winid = win_two }

        HunkNavigation.setup_keymaps(test_bufnr, state_one)
        HunkNavigation.setup_keymaps(test_bufnr, state_two)

        assert.is_true(
            is_buffer_local(get_keymap_in_buf(test_bufnr, keymaps.next_hunk))
        )

        HunkNavigation.restore_keymaps(test_bufnr)

        -- Emptiness, not iteration order: `next` on a non-empty keymap dict
        -- returns an arbitrary key, so comparing to nil passed by luck.
        assert.equal(
            vim.tbl_isempty(get_keymap_in_buf(test_bufnr, keymaps.next_hunk)),
            true
        )
        assert.equal(
            vim.tbl_isempty(get_keymap_in_buf(test_bufnr, keymaps.prev_hunk)),
            true
        )
    end)

    describe("save_keymap desc filter", function()
        local original_keymaps

        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
            original_keymaps = vim.deepcopy(Config.keymaps.diff_preview)
            Config.keymaps.diff_preview.next_hunk = "<leader>hn"
            Config.keymaps.diff_preview.prev_hunk = "<leader>hp"
        end)

        after_each(function()
            Config.keymaps.diff_preview = original_keymaps
            BufHelpers.keymap_del(test_bufnr, "n", "<leader>hn")
            BufHelpers.keymap_del(test_bufnr, "n", "<leader>hp")
            pcall(vim.keymap.del, "n", "<leader>hn")
            pcall(vim.keymap.del, "n", "<leader>hp")
            HunkNavigation.clear_state(test_bufnr)
        end)

        it(
            "saves and restores a user mapping with an unrelated desc",
            function()
                BufHelpers.keymap_set(
                    test_bufnr,
                    "n",
                    "<leader>hn",
                    ":echo 'user'<CR>",
                    { desc = "User next hunk" }
                )

                HunkNavigation.setup_keymaps(test_bufnr)
                HunkNavigation.restore_keymaps(test_bufnr)

                local restored = get_keymap_in_buf(test_bufnr, "<leader>hn")
                assert.is_true(is_buffer_local(restored))
                assert.equal(restored.rhs, ":echo 'user'<CR>")
            end
        )

        it(
            "does not save a mapping whose desc marks it as Agentic's",
            function()
                BufHelpers.keymap_set(
                    test_bufnr,
                    "n",
                    "<leader>hn",
                    ":echo 'ours'<CR>",
                    { desc = "Go to next hunk - Agentic DiffPreview" }
                )

                HunkNavigation.setup_keymaps(test_bufnr)
                HunkNavigation.restore_keymaps(test_bufnr)

                assert.is_true(
                    vim.tbl_isempty(get_keymap_in_buf(test_bufnr, "<leader>hn"))
                )
            end
        )

        it("saves a mapping that carries no desc", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                ":echo 'no desc'<CR>"
            )

            HunkNavigation.setup_keymaps(test_bufnr)
            HunkNavigation.restore_keymaps(test_bufnr)

            local restored = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_true(is_buffer_local(restored))
            assert.equal(restored.rhs, ":echo 'no desc'<CR>")
        end)

        it("does not save a global mapping", function()
            vim.keymap.set("n", "<leader>hn", ":echo 'global'<CR>")

            HunkNavigation.setup_keymaps(test_bufnr)
            HunkNavigation.restore_keymaps(test_bufnr)

            local restored = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_false(is_buffer_local(restored))
            assert.equal(":echo 'global'<CR>", restored.rhs)
        end)
    end)
end)
