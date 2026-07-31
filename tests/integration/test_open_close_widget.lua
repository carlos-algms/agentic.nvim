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

        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        -- Headless width 80; chat takes 40% = 32, plus 1 separator, leaving 47
        local original_width = child.api.nvim_win_get_width(initial_winid)
        assert.equal(47, original_width)
    end)

    it("toggles the widget to show and hide it", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local filetypes = get_tabpage_filetypes(0)
        assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        filetypes = get_tabpage_filetypes(0)
        assert.same({ "" }, filetypes)
    end)

    it("Creates a session per open, never per tabpage", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

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

        child.lua([[
            vim.ui.select = function(items, _, on_choice)
                on_choice(items[1])
            end
            require("agentic").new_session()
        ]])
        child.flush()

        -- Tab2 shows its own widget; tab1 keeps the first
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
            require("agentic.session_registry").sessions[2].widget:get_visible_tab_id()
                == nil
        ]]))
    end)

    it("handles tabclose while in insert mode without errors", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Triggers ModeChanged
        child.cmd("startinsert")

        -- Toggling in a second tab MOVES the widget, hiding it in tab 1; insert
        -- mode must survive that round trip
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local mode = child.fn.mode()
        assert.equal(mode, "i")

        -- Closing in insert mode runs the deferred `hide` and `ModeChanged`
        -- handler during cleanup; neither may error.
        --
        -- Neither host-side `vim.uv.sleep` nor `assert.has_no_errors` sees that:
        -- the sleep blocks THIS process while the callbacks run in the child, and
        -- an error inside the child's `vim.schedule` never propagates out of an
        -- RPC call. It lands in the child's message history, so that is asserted.
        child.cmd("messages clear")
        child.cmd("tabclose!")
        child.flush()

        assert.equal("", child.cmd_capture("messages"))
    end)

    it("tabclose on widget tab leaves first tab clean", function()
        --- Counts only user-visible windows. The session survives its tab, so the
        --- deferred `hide` recreates the chat buffer's hidden float — ADR 0001's
        --- fold anchor — and `relative = "editor"` puts it in the current tab,
        --- here the survivor. `nvim_tabpage_list_wins` counts it despite
        --- `hide = true` and `focusable = false`.
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

        local initial_windows = count_visible_windows(0)

        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local current_bufnr = child.api.nvim_get_current_buf()
        local expected_input_bufnr = child.lua_get([[
(function()
    local session = require("agentic.session_registry").current()
    return session.widget.buf_nrs.input
end)()
]])
        assert.equal(expected_input_bufnr, current_bufnr)

        assert.has_no_errors(function()
            child.cmd("tabclose")
            child.flush()
        end)

        local current_tab = child.api.nvim_get_current_tabpage()
        assert.equal(1, current_tab)

        local final_windows = count_visible_windows(0)

        assert.equal(initial_windows, final_windows)
        assert.equal(1, final_windows)
    end)
end)
