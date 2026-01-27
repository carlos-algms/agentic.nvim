local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Buffer Naming", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("buffer names mirror header titles", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local chat_bufname = child.lua_get([[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").sessions[tab_id]
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.chat)
end)()
]])

        local basename = child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], chat_bufname)
        )

        -- Buffer basename should start with the header title
        local has_prefix = child.lua_get(
            string.format(
                [[vim.startswith("%s", "󰻞 Agentic Chat")]],
                basename
            )
        )
        assert.is_true(has_prefix)
    end)

    it("uses invisible suffix for uniqueness across instances", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab1_name = child.lua_get([[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").sessions[tab_id]
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.input)
end)()
]])

        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab2_name = child.lua_get([[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").sessions[tab_id]
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.input)
end)()
]])

        -- Names are different internally
        assert.is_not.equal(tab1_name, tab2_name)

        -- But basenames appear identical to users (suffix invisible)
        local base1 = child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], tab1_name)
        )
        local base2 = child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], tab2_name)
        )

        -- Both start with "󰦨 Prompt" (rest is invisible)
        local has_prefix1 = child.lua_get(
            string.format([[vim.startswith("%s", "󰦨 Prompt")]], base1)
        )
        local has_prefix2 = child.lua_get(
            string.format([[vim.startswith("%s", "󰦨 Prompt")]], base2)
        )

        assert.is_true(has_prefix1)
        assert.is_true(has_prefix2)
    end)

    it("prevents buffer name collision errors", function()
        -- Create 5 tabpages with widgets
        for _ = 1, 5 do
            child.lua([[ require("agentic").toggle() ]])
            child.flush()
            child.cmd("tabnew")
        end

        -- Verify all sessions created successfully (no E95 errors)
        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])

        assert.equal(5, session_count)
    end)

    it("each panel has distinct buffer name prefix", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Test the panels that are always visible (chat, input)
        -- code, files, and todos are dynamic windows - names set when shown
        local panels = { "chat", "input" }
        local expected_prefixes = {
            chat = "󰻞 Agentic Chat",
            input = "󰦨 Prompt",
        }

        for _, panel in ipairs(panels) do
            local bufname = child.lua_get(string.format(
                [[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").sessions[tab_id]
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.%s)
end)()
]],
                panel
            ))

            local basename = child.lua_get(
                string.format([[vim.fn.fnamemodify("%s", ":t")]], bufname)
            )

            local expected_prefix = expected_prefixes[panel]

            -- Verify basename is not empty and contains expected text
            assert.is_not.equal("", bufname)
            assert.is_not.equal("", basename)
            -- Just check that the expected text appears in basename
            -- (suffix is invisible so won't affect display)
            assert.is_true(basename:find(expected_prefix, 1, true) ~= nil)
        end
    end)
end)
