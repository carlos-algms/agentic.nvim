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

    --- Gets buffer basename for a panel in the current tabpage
    --- @param panel string Panel name (chat, input, code, files, todos)
    --- @return string basename
    local function get_panel_basename(panel)
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
        return child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], bufname)
        )
    end

    it("buffer names mirror header titles", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local basename = get_panel_basename("chat")

        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it("adds tab suffix for multiple instances", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab1_basename = get_panel_basename("input")

        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab2_basename = get_panel_basename("input")

        -- First instance starts with title (no tab suffix)
        assert.is_true(vim.startswith(tab1_basename, "󰦨 Prompt"))
        assert.is_nil(tab1_basename:match("%(Tab %d+%)"))

        -- Second instance has visible "(Tab N)" suffix
        assert.is_true(vim.startswith(tab2_basename, "󰦨 Prompt"))
        assert.is_not_nil(tab2_basename:match("%(Tab %d+%)"))

        -- Names are unique
        assert.is_not.equal(tab1_basename, tab2_basename)
    end)

    it("prevents buffer name collision errors", function()
        for _ = 1, 5 do
            child.lua([[ require("agentic").toggle() ]])
            child.flush()
            child.cmd("tabnew")
        end

        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").sessions)
        ]])

        assert.equal(5, session_count)
    end)

    it("each panel has distinct buffer name prefix", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local expected_prefixes = {
            chat = "󰻞 Agentic Chat",
            input = "󰦨 Prompt",
        }

        for panel, expected_prefix in pairs(expected_prefixes) do
            local basename = get_panel_basename(panel)

            assert.is_not.equal("", basename)
            assert.is_true(basename:find(expected_prefix, 1, true) ~= nil)
        end
    end)
end)
