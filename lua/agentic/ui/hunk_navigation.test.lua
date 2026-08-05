local assert = require("tests.helpers.assert")
local spy_module = require("tests.helpers.spy")
local BufHelpers = require("agentic.utils.buf_helpers")
local AgenticConfig = require("agentic.config")
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
        local base_tabs
        local saved_layout
        local win_call_stub

        before_each(function()
            base_tabs = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                base_tabs[tabpage] = true
            end
            saved_layout = AgenticConfig.diff_preview.layout
            win_call_stub = nil
            vim.cmd("buffer " .. test_bufnr)
            winid = vim.api.nvim_get_current_win()
            HunkNavigation.setup_keymaps(test_bufnr)
        end)

        after_each(function()
            if win_call_stub then
                win_call_stub:revert()
                win_call_stub = nil
            end
            AgenticConfig.diff_preview.layout = saved_layout
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
                if not base_tabs[tabpage] then
                    pcall(function()
                        vim.api.nvim_set_current_tabpage(tabpage)
                        vim.cmd("tabclose!")
                    end)
                end
            end
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

        it("uses the painted window from the provided owner state", function()
            vim.cmd("tabnew")
            local owner_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(owner_win, test_bufnr)
            vim.api.nvim_win_set_cursor(owner_win, { 1, 0 })

            vim.cmd("tabnew")
            local foreign_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(foreign_win, test_bufnr)
            vim.api.nvim_win_set_cursor(foreign_win, { 1, 0 })
            add_hunk(test_bufnr, test_ns, 10)

            HunkNavigation.navigate_next(test_bufnr, {
                preview_bufnr = test_bufnr,
                preview_winid = owner_win,
            })

            assert.equal(11, vim.api.nvim_win_get_cursor(owner_win)[1])
            assert.equal(1, vim.api.nvim_win_get_cursor(foreign_win)[1])
        end)

        it(
            "does not navigate a buffer unowned by the provided state",
            function()
                add_hunk(test_bufnr, test_ns, 10)

                HunkNavigation.navigate_next(test_bufnr, {})

                assert.equal(1, vim.api.nvim_win_get_cursor(winid)[1])
            end
        )

        it("prefers an owned split window over the inline preview", function()
            AgenticConfig.diff_preview.layout = "split"
            local preview_bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                preview_bufnr,
                0,
                -1,
                false,
                { "preview" }
            )
            local preview_winid = vim.api.nvim_open_win(
                preview_bufnr,
                false,
                { split = "right", win = winid }
            )
            win_call_stub = spy_module.stub(vim.api, "nvim_win_call")
            add_hunk(test_bufnr, test_ns, 10)

            HunkNavigation.navigate_next(test_bufnr, {
                preview_bufnr = preview_bufnr,
                preview_winid = preview_winid,
                split_state = {
                    ["/tmp/owned-split.lua"] = {
                        original_bufnr = test_bufnr,
                        original_winid = winid,
                        new_bufnr = preview_bufnr,
                        new_winid = preview_winid,
                        file_path = "/tmp/owned-split.lua",
                    },
                },
            })

            local called_winid = win_call_stub.calls[1]
                and win_call_stub.calls[1][1]
            local win_call_count = win_call_stub.call_count
            win_call_stub:revert()
            win_call_stub = nil
            pcall(vim.api.nvim_win_close, preview_winid, true)
            pcall(vim.api.nvim_buf_delete, preview_bufnr, { force = true })

            assert.equal(1, win_call_count)
            assert.equal(winid, called_winid)
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

        it("preserves the original keymap across repeated setup", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                ":echo 'original'<CR>"
            )
            local original = get_keymap_in_buf(test_bufnr, "<leader>hn").rhs

            HunkNavigation.setup_keymaps(test_bufnr, nil)
            HunkNavigation.setup_keymaps(test_bufnr, nil)
            HunkNavigation.restore_keymaps(test_bufnr, nil)

            assert.equal(
                original,
                get_keymap_in_buf(test_bufnr, "<leader>hn").rhs
            )
        end)

        it("keeps one entry for repeated setup by the same owner", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                ":echo 'original'<CR>"
            )
            --- @type agentic.ui.DiffState
            local state = {}

            HunkNavigation.setup_keymaps(test_bufnr, state)
            HunkNavigation.setup_keymaps(test_bufnr, state)
            HunkNavigation.restore_keymaps(test_bufnr, state)

            assert.equal(
                ":echo 'original'<CR>",
                get_keymap_in_buf(test_bufnr, "<leader>hn").rhs
            )
        end)

        it("restores noremap silent expr and nowait", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                "v:count",
                { noremap = true, silent = true, expr = true, nowait = true }
            )

            HunkNavigation.setup_keymaps(test_bufnr, nil)
            HunkNavigation.restore_keymaps(test_bufnr, nil)

            local restored = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.equal(1, restored.noremap)
            assert.equal(1, restored.silent)
            assert.equal(1, restored.expr)
            assert.equal(1, restored.nowait)
        end)

        it("restores a recursive mapping with its other flags", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                "v:count",
                { remap = true, silent = true, expr = true, nowait = true }
            )

            HunkNavigation.setup_keymaps(test_bufnr, nil)
            HunkNavigation.restore_keymaps(test_bufnr, nil)

            local restored = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.equal(0, restored.noremap)
            assert.equal(1, restored.silent)
            assert.equal(1, restored.expr)
            assert.equal(1, restored.nowait)
        end)

        it(
            "keeps the newer owner callback when the older owner clears",
            function()
                --- @type agentic.ui.DiffState
                local older = {}
                --- @type agentic.ui.DiffState
                local newer = {}
                local navigate_spy =
                    spy_module.on(HunkNavigation, "navigate_next")

                HunkNavigation.setup_keymaps(test_bufnr, older)
                HunkNavigation.setup_keymaps(test_bufnr, newer)
                HunkNavigation.restore_keymaps(test_bufnr, older)

                local mapping = get_keymap_in_buf(test_bufnr, "<leader>hn")
                assert.equal("function", type(mapping.callback))
                mapping.callback()
                assert.spy(navigate_spy).was.called_with(test_bufnr, newer)
                navigate_spy:revert()
            end
        )

        it(
            "reinstalls the older owner callback when the newer owner clears",
            function()
                --- @type agentic.ui.DiffState
                local older = {}
                --- @type agentic.ui.DiffState
                local newer = {}
                local navigate_spy =
                    spy_module.on(HunkNavigation, "navigate_next")

                HunkNavigation.setup_keymaps(test_bufnr, older)
                HunkNavigation.setup_keymaps(test_bufnr, newer)
                HunkNavigation.restore_keymaps(test_bufnr, newer)

                local mapping = get_keymap_in_buf(test_bufnr, "<leader>hn")
                assert.equal("function", type(mapping.callback))
                mapping.callback()
                assert.spy(navigate_spy).was.called_with(test_bufnr, older)
                navigate_spy:revert()
            end
        )

        it("restores the user mapping after the final owner clears", function()
            BufHelpers.keymap_set(
                test_bufnr,
                "n",
                "<leader>hn",
                ":echo 'user'<CR>"
            )
            --- @type agentic.ui.DiffState
            local first = {}
            --- @type agentic.ui.DiffState
            local second = {}

            HunkNavigation.setup_keymaps(test_bufnr, first)
            HunkNavigation.setup_keymaps(test_bufnr, second)
            HunkNavigation.restore_keymaps(test_bufnr, first)
            assert.is_not.equal(
                ":echo 'user'<CR>",
                get_keymap_in_buf(test_bufnr, "<leader>hn").rhs
            )
            HunkNavigation.restore_keymaps(test_bufnr, second)

            assert.equal(
                ":echo 'user'<CR>",
                get_keymap_in_buf(test_bufnr, "<leader>hn").rhs
            )
        end)

        it("clears state after restore", function()
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
    --- @type table<integer, true>
    local baseline_tabs
    --- @type integer[]
    local created_windows
    --- @type integer[]
    local created_buffers

    --- @return integer bufnr
    local function create_buffer()
        local bufnr = vim.api.nvim_create_buf(false, true)
        created_buffers[#created_buffers + 1] = bufnr
        return bufnr
    end

    --- @return integer winid
    local function create_tab()
        vim.cmd("tabnew")
        local winid = vim.api.nvim_get_current_win()
        created_windows[#created_windows + 1] = winid
        return winid
    end

    --- @param bufnr integer
    --- @param parent integer
    --- @return integer winid
    local function create_split(bufnr, parent)
        local winid = vim.api.nvim_open_win(bufnr, false, {
            split = "right",
            win = parent,
        })
        created_windows[#created_windows + 1] = winid
        return winid
    end

    before_each(function()
        baseline_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            baseline_tabs[tabpage] = true
        end
        created_windows = {}
        created_buffers = {}
        saved_layout = Config.diff_preview.layout
        Config.diff_preview.layout = "split"

        test_bufnr = create_buffer()
        local lines = {}
        for i = 1, 60 do
            lines[#lines + 1] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, lines)
    end)

    after_each(function()
        Config.diff_preview.layout = saved_layout
        for _, winid in ipairs(created_windows) do
            if BufHelpers.is_win_usable(winid) then
                pcall(vim.api.nvim_win_close, winid, true)
            end
        end

        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if
                not baseline_tabs[tabpage]
                and vim.api.nvim_tabpage_is_valid(tabpage)
            then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end

        for _, bufnr in ipairs(created_buffers) do
            HunkNavigation.clear_state(bufnr)
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end)

    it("navigates the split's own window, not another tab's", function()
        -- Same buffer in two tabs. Only `split_state.original_winid` says which
        -- window carries the diff; without it the lookup takes tabpage order,
        -- hits a window not in diff mode, and reports "no more hunks" while the
        -- real diff sits untouched.
        local foreign_win = create_tab()
        vim.api.nvim_win_set_buf(foreign_win, test_bufnr)
        vim.api.nvim_win_set_cursor(foreign_win, { 1, 0 })

        local split_win = create_tab()
        vim.api.nvim_win_set_buf(split_win, test_bufnr)
        vim.api.nvim_win_set_cursor(split_win, { 1, 0 })

        -- Identical except line 30, so `]c` from line 1 has somewhere to go.
        local scratch = create_buffer()
        local scratch_lines =
            vim.api.nvim_buf_get_lines(test_bufnr, 0, -1, false)
        scratch_lines[30] = "changed line 30"
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, scratch_lines)
        local scratch_win = create_split(scratch, split_win)

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
                local bufnr = create_buffer()
                local lines = {}
                for i = 1, 60 do
                    lines[#lines + 1] = label .. " line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                local original_winid = create_tab()
                vim.api.nvim_win_set_buf(original_winid, bufnr)
                vim.api.nvim_win_set_cursor(original_winid, { 1, 0 })

                local scratch = create_buffer()
                local scratch_lines = vim.deepcopy(lines)
                scratch_lines[30] = label .. " changed line 30"
                vim.api.nvim_buf_set_lines(scratch, 0, -1, false, scratch_lines)
                local scratch_winid = create_split(scratch, original_winid)

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

            -- A third buffer has no entry in this owner state. It must not use
            -- an arbitrary split or fall back to unowned inline navigation.
            local buf_c = create_buffer()
            local lines_c = {}
            for i = 1, 60 do
                lines_c[#lines_c + 1] = "gamma line " .. i
            end
            vim.api.nvim_buf_set_lines(buf_c, 0, -1, false, lines_c)

            local win_c = create_tab()
            vim.api.nvim_win_set_buf(win_c, buf_c)
            vim.api.nvim_win_set_cursor(win_c, { 1, 0 })
            add_hunk(buf_c, test_ns, 10)

            HunkNavigation.navigate_next(buf_c, diff_state)

            assert.equal(1, vim.api.nvim_win_get_cursor(win_c)[1])

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
        local only_win = create_tab()
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
        local foreign_win = create_tab()
        vim.api.nvim_win_set_buf(foreign_win, test_bufnr)
        vim.api.nvim_win_set_cursor(foreign_win, { 1, 0 })

        create_tab()
        local owner_tab = vim.api.nvim_get_current_tabpage()
        -- Second window in the owner's tab, so closing the painted one leaves
        -- the tabpage (and the scope) alive.
        vim.cmd("split")
        local owner_win = vim.api.nvim_get_current_win()
        created_windows[#created_windows + 1] = owner_win
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
