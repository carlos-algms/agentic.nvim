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

    it("uses custom buffer_name from windows config when set", function()
        child.lua([[
            require("agentic").setup({ windows = { chat = { buffer_name = "My Chat" } } })
            require("agentic").toggle()
        ]])
        child.flush()

        local basename = get_panel_basename("chat")
        assert.is_true(vim.startswith(basename, "My Chat"))
    end)

    it("uses buffer_name function to derive name from header parts", function()
        child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function(parts)
                            return "Custom: " .. parts.title
                        end,
                    },
                },
            })
            require("agentic").toggle()
        ]])
        child.flush()

        local basename = get_panel_basename("chat")
        assert.is_true(vim.startswith(basename, "Custom: 󰻞 Agentic Chat"))
    end)

    it("falls back to header title when buffer_name not set", function()
        child.lua([[
            require("agentic").setup({})
            require("agentic").toggle()
        ]])
        child.flush()

        local basename = get_panel_basename("chat")
        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it("falls back to header title when buffer_name function throws", function()
        child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function()
                            error("intentional error")
                        end,
                    },
                },
            })
            require("agentic").toggle()
        ]])
        child.flush()

        local basename = get_panel_basename("chat")
        assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
    end)

    it(
        "falls back to header title when buffer_name function returns nil",
        function()
            child.lua([[
            require("agentic").setup({
                windows = {
                    chat = {
                        buffer_name = function()
                            return nil
                        end,
                    },
                },
            })
            require("agentic").toggle()
        ]])
            child.flush()

            local basename = get_panel_basename("chat")
            assert.is_true(vim.startswith(basename, "󰻞 Agentic Chat"))
        end
    )

    it(
        "assigns unique names when two panels share the same buffer_name",
        function()
            child.lua([[
            require("agentic").setup({
                windows = {
                    chat = { buffer_name = "Shared Name" },
                    input = { buffer_name = "Shared Name" },
                },
            })
            require("agentic").toggle()
        ]])
            child.flush()

            local chat_basename = get_panel_basename("chat")
            local input_basename = get_panel_basename("input")

            assert.is_true(vim.startswith(chat_basename, "Shared Name"))
            assert.is_true(vim.startswith(input_basename, "Shared Name"))
            assert.is_not.equal(chat_basename, input_basename)
        end
    )

    it("adds tab suffix to custom buffer_name across tabs", function()
        child.lua([[
            require("agentic").setup({ windows = { chat = { buffer_name = "My Chat" } } })
            require("agentic").toggle()
        ]])
        child.flush()

        local tab1_basename = get_panel_basename("chat")

        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local tab2_basename = get_panel_basename("chat")

        -- First instance: custom name, no tab suffix
        assert.is_true(vim.startswith(tab1_basename, "My Chat"))
        assert.is_nil(tab1_basename:match("%(Tab %d+%)"))

        -- Second instance: custom name plus visible "(Tab N)" suffix
        assert.is_true(vim.startswith(tab2_basename, "My Chat"))
        assert.is_not_nil(tab2_basename:match("%(Tab %d+%)"))

        -- Names are unique
        assert.is_not.equal(tab1_basename, tab2_basename)
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
