local assert = require("tests.helpers.assert")
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

            if next(after_next) ~= nil then
                assert.is_true(is_buffer_local(after_next))
                assert.equal(after_next.rhs, original_rhs)
            end
            assert.equal(next(after_prev), nil)
        end)

        it("clears state after restore", function()
            HunkNavigation.setup_keymaps(test_bufnr)
            add_hunk(test_bufnr, test_ns, 1)
            get_hunk_anchors(test_bufnr)

            HunkNavigation.restore_keymaps(test_bufnr)

            local anchors = get_hunk_anchors(test_bufnr)
            assert.equal(#anchors, 1)
        end)
    end)
end)
