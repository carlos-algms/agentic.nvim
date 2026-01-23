local assert = require("tests.helpers.assert")
local HunkNavigation = require("agentic.ui.hunk_navigation")

--- Access private function for testing
--- @param bufnr number
--- @param namespace_id number
--- @return integer[]
local function get_hunk_anchors(bufnr, namespace_id)
    ---@diagnostic disable-next-line: invisible
    return HunkNavigation._get_hunk_anchors(bufnr, namespace_id)
end

--- Helper to create extmark with virt_lines
--- @param bufnr number
--- @param ns number
--- @param line number
local function add_hunk(bufnr, ns, line)
    vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
        virt_lines = { { { "hunk " .. line, "Comment" } } },
    })
end

--- Get keymap info in buffer context
--- @param bufnr number
--- @param key string
--- @return table
local function get_keymap_in_buf(bufnr, key)
    return vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(key, "n", false, true)
    end)
end

--- Check if keymap is buffer-local
--- @param map table|nil
--- @return boolean
local function is_buffer_local(map)
    return map and map.buffer == 1 or false
end

local test_ns = vim.api.nvim_create_namespace("test_hunk_navigation")

describe("hunk_navigation", function()
    local test_bufnr

    before_each(function()
        test_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, {
            "line 1",
            "line 2",
            "line 3",
            "line 4",
            "line 5",
        })
    end)

    after_each(function()
        HunkNavigation.clear_state(test_bufnr)
        pcall(vim.api.nvim_buf_delete, test_bufnr, { force = true })
    end)

    describe("_get_hunk_anchors", function()
        it(
            "returns sorted anchors and ignores non-virt_lines extmarks",
            function()
                -- Test sorting and filtering in one test using Pairwise Testing
                add_hunk(test_bufnr, test_ns, 2) -- Middle
                add_hunk(test_bufnr, test_ns, 0) -- First
                vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 3, 0, {
                    virt_text = { { "not a hunk", "Comment" } }, -- Should be ignored
                })
                add_hunk(test_bufnr, test_ns, 4) -- Last

                local anchors = get_hunk_anchors(test_bufnr, test_ns)
                assert.equal(#anchors, 3)
                assert.equal(anchors[1], 0)
                assert.equal(anchors[2], 2)
                assert.equal(anchors[3], 4)
            end
        )

        it("caches results on subsequent calls", function()
            add_hunk(test_bufnr, test_ns, 1)

            local anchors1 = get_hunk_anchors(test_bufnr, test_ns)
            local anchors2 = get_hunk_anchors(test_bufnr, test_ns)

            assert.equal(anchors1, anchors2)
        end)
    end)

    describe("navigate_next and navigate_prev", function()
        local winid

        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
            winid = vim.api.nvim_get_current_win()
        end)

        after_each(function()
            HunkNavigation.clear_state(test_bufnr)
        end)

        it("navigates through multiple hunks with wrapping", function()
            add_hunk(test_bufnr, test_ns, 1)
            add_hunk(test_bufnr, test_ns, 3)

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            -- Forward navigation: start -> 1st -> 2nd -> wrap to 1st
            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

            -- Backward navigation: wrap to last -> 1st
            HunkNavigation.navigate_prev(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

            HunkNavigation.navigate_prev(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)
        end)

        it("wraps to itself with single hunk", function()
            add_hunk(test_bufnr, test_ns, 1)

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            local pos1 = vim.api.nvim_win_get_cursor(winid)[1]

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            local pos2 = vim.api.nvim_win_get_cursor(winid)[1]

            assert.equal(pos1, pos2)
        end)
    end)

    describe("setup_keymaps and restore_keymaps", function()
        local Config
        local original_keymaps

        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
            Config = require("agentic.config")
            original_keymaps = vim.deepcopy(Config.keymaps.diff_preview)
            -- Use custom test keybindings to avoid conflicts with native vim keymaps
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

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            local during_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            assert.is_true(is_buffer_local(during_map))

            HunkNavigation.restore_keymaps(test_bufnr)

            -- CRITICAL: If global was saved and restored, it would be buffer-local
            -- (because restore_keymaps always sets opts.buffer = bufnr)
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

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            local next_map = get_keymap_in_buf(test_bufnr, "<leader>hn")
            local prev_map = get_keymap_in_buf(test_bufnr, "<leader>hp")
            assert.is_not_nil(next_map)
            assert.is_not_nil(prev_map)
            assert.is_true(is_buffer_local(next_map))
            assert.is_true(is_buffer_local(prev_map))

            HunkNavigation.restore_keymaps(test_bufnr)

            local after_next = get_keymap_in_buf(test_bufnr, "<leader>hn")
            local after_prev = get_keymap_in_buf(test_bufnr, "<leader>hp")

            -- Verify navigation keymaps removed and originals restored
            if next(after_next) ~= nil then
                assert.is_true(is_buffer_local(after_next))
                assert.equal(after_next.rhs, original_rhs)
            end
            -- Prev keymap should be removed (didn't exist before)
            assert.equal(next(after_prev), nil)
        end)

        it("clears module state after restore", function()
            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            add_hunk(test_bufnr, test_ns, 1)
            get_hunk_anchors(test_bufnr, test_ns)

            HunkNavigation.restore_keymaps(test_bufnr)

            local anchors = get_hunk_anchors(test_bufnr, test_ns)
            assert.equal(#anchors, 1)
        end)
    end)

    describe("clear_state", function()
        it("clears per-buffer state", function()
            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            add_hunk(test_bufnr, test_ns, 1)
            get_hunk_anchors(test_bufnr, test_ns)

            HunkNavigation.clear_state(test_bufnr)

            local anchors_after = get_hunk_anchors(test_bufnr, test_ns)
            assert.equal(#anchors_after, 1)
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
        end)

        after_each(function()
            Config.diff_preview.center_on_navigate_hunks =
                original_center_setting
            HunkNavigation.clear_state(test_bufnr)
        end)

        it(
            "CRITICAL: navigates even when center_on_navigate_hunks = false",
            function()
                -- This test would have caught the bug where navigation was blocked
                -- when get_scroll_cmd returned nil (centering disabled)
                Config.diff_preview.center_on_navigate_hunks = false

                add_hunk(test_bufnr, test_ns, 1)
                add_hunk(test_bufnr, test_ns, 3)

                HunkNavigation.setup_keymaps(test_bufnr, test_ns)

                -- Start at line 1
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                -- Navigate to first hunk (line 2)
                HunkNavigation.navigate_next(test_bufnr, test_ns)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

                -- Navigate to second hunk (line 4)
                HunkNavigation.navigate_next(test_bufnr, test_ns)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)

                -- Navigate back to first hunk (line 2)
                HunkNavigation.navigate_prev(test_bufnr, test_ns)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)
            end
        )

        it(
            "navigates with centering when center_on_navigate_hunks = true",
            function()
                Config.diff_preview.center_on_navigate_hunks = true

                add_hunk(test_bufnr, test_ns, 1)
                add_hunk(test_bufnr, test_ns, 3)

                HunkNavigation.setup_keymaps(test_bufnr, test_ns)

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                HunkNavigation.navigate_next(test_bufnr, test_ns)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 2)

                HunkNavigation.navigate_next(test_bufnr, test_ns)
                assert.equal(vim.api.nvim_win_get_cursor(winid)[1], 4)
            end
        )
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
            "returns empty string when center_on_navigate_hunks = false",
            function()
                Config.diff_preview.center_on_navigate_hunks = false

                add_hunk(test_bufnr, test_ns, 1)

                local scroll_cmd =
                    HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1, test_ns)

                assert.equal(scroll_cmd, "")
            end
        )

        it("returns empty string when no extmarks found", function()
            Config.diff_preview.center_on_navigate_hunks = true

            -- Don't add any hunks - no extmarks at line 1
            local scroll_cmd =
                HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1, test_ns)

            assert.equal(scroll_cmd, "")
        end)

        it("returns 'zz' for small hunks (< half window height)", function()
            Config.diff_preview.center_on_navigate_hunks = true

            -- Create small hunk (1 virt_line)
            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 1, 0, {
                virt_lines = { { { "small hunk", "Comment" } } },
            })

            local scroll_cmd =
                HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1, test_ns)

            assert.equal(scroll_cmd, "zz")
        end)

        it("returns 'zt' for large hunks (> half window height)", function()
            Config.diff_preview.center_on_navigate_hunks = true

            local win_height = vim.api.nvim_win_get_height(winid)
            local large_virt_lines = {}
            for i = 1, math.floor(win_height / 2) + 2 do
                table.insert(large_virt_lines, { { "line " .. i, "Comment" } })
            end

            vim.api.nvim_buf_set_extmark(test_bufnr, test_ns, 1, 0, {
                virt_lines = large_virt_lines,
            })

            local scroll_cmd =
                HunkNavigation.get_scroll_cmd(test_bufnr, winid, 1, test_ns)

            assert.equal(scroll_cmd, "zt")
        end)
    end)
end)
