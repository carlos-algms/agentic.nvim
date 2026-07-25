local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Open and Close Chat Widget", function()
    local child = Child:new()

    --- @param tabpage number
    --- @return string[] sorted filetypes (hidden floats excluded)
    local function get_tabpage_filetypes(tabpage)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local cfg = child.api.nvim_win_get_config(winid)
            if not cfg.hide then
                local bufnr = child.api.nvim_win_get_buf(winid)
                local ft =
                    child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
                table.insert(filetypes, ft)
            end
        end
        table.sort(filetypes)
        return filetypes
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("Opens the widget with chat and prompt windows", function()
        local initial_winid = child.api.nvim_get_current_win()

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Should have: empty filetype (original window), AgenticChat, AgenticInput
        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        -- 80 - default neovim headless width
        -- 40% of 80 = 32 (chat window)
        -- 1 separator
        -- Check that original window width is reduced (80 - 32 - 1 separator = 47)
        local original_width = child.api.nvim_win_get_width(initial_winid)
        assert.equal(47, original_width)
    end)

    it("toggles the widget to show and hide it", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Should have: empty filetype (original window), AgenticChat, AgenticInput
        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- After hide, should only have original window
        filetypes = get_tabpage_filetypes(0)
        assert.same({ "" }, filetypes)
    end)

    it("Creates a session per open, never per tabpage", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Tab1 should have: empty filetype, AgenticChat, AgenticInput
        local tab1_filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, tab1_filetypes)

        local tab1_id = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")

        local tab2_id = child.api.nvim_get_current_tabpage()
        assert.is_not.equal(tab1_id, tab2_id)

        -- A new tabpage on its own creates nothing
        assert.equal(
            1,
            child.lua_get([[
                vim.tbl_count(require("agentic.session_registry").sessions)
            ]])
        )

        child.lua([[ require("agentic").new_session() ]])
        child.flush()

        -- Tab2 shows its own widget, and tab1 keeps showing the first one
        assert.same(
            { "", "AgenticChat", "AgenticInput" },
            get_tabpage_filetypes(0)
        )
        assert.same(
            { "", "AgenticChat", "AgenticInput" },
            get_tabpage_filetypes(tab1_id)
        )

        assert.equal(
            2,
            child.lua_get([[
                vim.tbl_count(require("agentic.session_registry").sessions)
            ]])
        )

        assert.has_no_errors(function()
            child.cmd("tabclose")
            child.flush()
        end)

        -- Sessions no longer die with their tab: the second one survives hidden
        assert.equal(
            2,
            child.lua_get([[
                vim.tbl_count(require("agentic.session_registry").sessions)
            ]])
        )
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[2].widget:visible_tab()
                == nil
        ]]))
    end)

    it("handles tabclose while in insert mode without errors", function()
        -- Open widget
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Enter insert mode in input buffer (triggers ModeChanged)
        child.cmd("startinsert")

        -- Create second tab: toggling there MOVES the widget, hiding it in tab 1
        -- and showing it here, and insert mode must survive that round trip
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local mode = child.fn.mode()
        assert.equal(mode, "i")

        -- Close the second tab while in insert mode
        -- This should not error when ModeChanged fires during cleanup
        assert.has_no_errors(function()
            child.cmd("tabclose!")
            vim.uv.sleep(200)
        end)
    end)

    it("tabclose on widget tab leaves first tab clean", function()
        --- Counts only user-visible windows. The session now survives its tab, so
        --- the deferred `hide` recreates the chat buffer's hidden float — ADR
        --- 0001's fold anchor — and `relative = "editor"` puts it in whichever tab
        --- is current, here the surviving one. `nvim_tabpage_list_wins` counts it
        --- even though it is `hide = true` and `focusable = false`.
        --- @param tabpage integer
        --- @return integer count
        local function count_visible_windows(tabpage)
            return child.lua_get(([[
(function()
    local count = 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(%d)) do
        local cfg = vim.api.nvim_win_get_config(winid)
        if not cfg.hide and cfg.focusable then
            count = count + 1
        end
    end
    return count
end)()
]]):format(tabpage))
        end

        -- Start with clean first tab (no widget)
        local initial_windows = count_visible_windows(0)

        -- Create second tab and open widget there
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Ensure cursor is in input buffer
        local current_bufnr = child.api.nvim_get_current_buf()
        local expected_input_bufnr = child.lua_get([[
(function()
    local session = require("agentic.session_registry").current()
    return session.widget.buf_nrs.input
end)()
]])
        assert.equal(expected_input_bufnr, current_bufnr)

        -- Close the second tab
        assert.has_no_errors(function()
            child.cmd("tabclose")
            child.flush()
        end)

        -- Verify we're back on the first tab
        local current_tab = child.api.nvim_get_current_tabpage()
        assert.equal(1, current_tab)

        -- First tab should be clean (same number of windows as initially)
        local final_windows = count_visible_windows(0)

        assert.equal(initial_windows, final_windows)

        -- Should only have 1 window visible
        assert.equal(1, final_windows)
    end)
end)
