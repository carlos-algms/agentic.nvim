local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("session_manager", function()
    local child = Child:new()

    before_each(function()
        child.setup()

        child.lua([[
            local ACPTransportMock = require("tests.mocks.acp_transport_mock")
            package.loaded["agentic.acp.acp_transport"] = ACPTransportMock
            require("agentic").setup()
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    it("Opens the widget with chat and prompt windows", function()
        -- Get initial window width before toggle
        local initial_winid = child.api.nvim_get_current_win()

        child.lua([[ require("agentic").toggle() ]])

        -- Check that 3 windows are open (original + chat + prompt)
        local window_count = child.fn.winnr("$")
        assert.equal(3, window_count)

        -- Get all window IDs in current tabpage
        local winids = child.lua_get([[vim.api.nvim_tabpage_list_wins(0)]])

        -- Check filetypes of all windows
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            table.insert(filetypes, ft)
        end

        -- Sort for consistent comparison
        table.sort(filetypes)

        -- Should have: empty filetype (original window), AgenticChat, AgenticInput
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

        local window_count = child.fn.winnr("$")
        assert.equal(3, window_count)

        child.lua([[ require("agentic").toggle() ]])

        window_count = child.fn.winnr("$")
        assert.equal(1, window_count)
    end)

    it("Creates independent sessions per tabpage", function()
        child.lua([[ require("agentic").toggle() ]])

        local tab1_wincount = child.fn.winnr("$")
        assert.equal(3, tab1_wincount)

        local tab1_id = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")

        local tab2_id = child.api.nvim_get_current_tabpage()
        assert.is_not.equal(tab1_id, tab2_id)

        child.lua([[ require("agentic").toggle() ]])

        local tab2_wincount = child.fn.winnr("$")
        assert.equal(3, tab2_wincount)

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
end)
