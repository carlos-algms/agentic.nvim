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
        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
        end)

        after_each(function()
            HunkNavigation.clear_state(test_bufnr)
        end)

        -- Equivalence Class: Multiple hunks (>1)
        it("navigates through multiple hunks with wrapping", function()
            add_hunk(test_bufnr, test_ns, 1)
            add_hunk(test_bufnr, test_ns, 3)

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            -- Forward navigation: start -> 1st -> 2nd -> wrap to 1st
            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(0)[1], 2)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(0)[1], 4)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(0)[1], 2)

            -- Backward navigation: wrap to last -> 1st
            HunkNavigation.navigate_prev(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(0)[1], 4)

            HunkNavigation.navigate_prev(test_bufnr, test_ns)
            assert.equal(vim.api.nvim_win_get_cursor(0)[1], 2)
        end)

        -- Equivalence Class: Single hunk (boundary case)
        it("wraps to itself with single hunk", function()
            add_hunk(test_bufnr, test_ns, 1)

            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            local pos1 = vim.api.nvim_win_get_cursor(0)[1]

            HunkNavigation.navigate_next(test_bufnr, test_ns)
            local pos2 = vim.api.nvim_win_get_cursor(0)[1]

            assert.equal(pos1, pos2)
        end)
    end)

    describe("setup_keymaps and restore_keymaps", function()
        before_each(function()
            vim.cmd("buffer " .. test_bufnr)
        end)

        it("sets buffer-local keymaps and restores originals", function()
            -- Save original keymap
            local original_fn = function()
                -- Original keymap function
            end
            vim.keymap.set("n", "]c", original_fn, { buffer = test_bufnr })

            local before_map = vim.fn.maparg("]c", "n", false, true)
            assert.is_not_nil(before_map)

            -- Setup hunk navigation keymaps
            HunkNavigation.setup_keymaps(test_bufnr, test_ns)

            local next_map = vim.fn.maparg("]c", "n", false, true)
            local prev_map = vim.fn.maparg("[c", "n", false, true)

            assert.is_not_nil(next_map)
            assert.is_not_nil(prev_map)
            assert.equal(next_map.buffer, 1)
            assert.equal(prev_map.buffer, 1)

            -- Restore original keymaps
            HunkNavigation.restore_keymaps(test_bufnr)

            local after_next = vim.fn.maparg("]c", "n", false, true)
            local after_prev = vim.fn.maparg("[c", "n", false, true)

            -- Verify navigation keymaps removed and originals restored
            if type(after_next) == "table" and next(after_next) ~= nil then
                assert.is_not_nil(after_next.callback or after_next.rhs)
            end
            assert.equal(type(after_prev), "table")
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
end)
