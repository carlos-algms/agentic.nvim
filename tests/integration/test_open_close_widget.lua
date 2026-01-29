local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Open and Close Chat Widget", function()
    local child = Child:new()

    --- Gets sorted filetypes for all windows in the given tabpage
    --- @param tabpage number
    --- @return string[]
    local function get_tabpage_filetypes(tabpage)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            table.insert(filetypes, ft)
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

    it("Creates independent widgets per tabpage", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Tab1 should have: empty filetype, AgenticChat, AgenticInput
        local tab1_filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, tab1_filetypes)

        local tab1_id = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")

        local tab2_id = child.api.nvim_get_current_tabpage()
        assert.is_not.equal(tab1_id, tab2_id)

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Tab2 should also have: empty filetype, AgenticChat, AgenticInput
        local tab2_filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, tab2_filetypes)

        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])
        assert.equal(2, session_count)

        assert.has_no_errors(function()
            child.cmd("tabclose")
        end)

        local session_count_after = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])
        assert.equal(1, session_count_after)
    end)

    it("handles tabclose while in insert mode without errors", function()
        -- Open widget
        child.lua([[ require("agentic").toggle() ]])

        -- Enter insert mode in input buffer (triggers ModeChanged)
        child.cmd("startinsert")

        -- Create second tab
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])

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
        -- Start with clean first tab (no widget)
        local initial_windows = #child.api.nvim_tabpage_list_wins(0)

        -- Create second tab and open widget there
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Ensure cursor is in input buffer
        local current_bufnr = child.api.nvim_get_current_buf()
        local expected_input_bufnr = child.lua_get([[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").sessions[tab_id]
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
        local final_windows = #child.api.nvim_tabpage_list_wins(0)

        -- Debug: what windows exist?
        if final_windows ~= initial_windows then
            local winids = child.api.nvim_tabpage_list_wins(0)
            for i, winid in ipairs(winids) do
                local bufnr = child.api.nvim_win_get_buf(winid)
                local ft =
                    child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
                print(
                    string.format(
                        "Window %d: winid=%d bufnr=%d filetype='%s'",
                        i,
                        winid,
                        bufnr,
                        ft
                    )
                )
            end
        end

        assert.equal(initial_windows, final_windows)

        -- Should only have 1 window visible
        assert.equal(1, final_windows)
    end)
end)
