local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Destroy session keymap", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("destroys the current session with <localLeader>D", function()
        child.lua([[
            require("agentic").new_session({ auto_add_to_context = false })
        ]])
        child.flush()

        child.lua([[
            vim.ui.select = function(items, _, on_choice)
                on_choice(items[1])
            end
            require("agentic").new_session({ auto_add_to_context = false })
            require("agentic.session_registry").show_session(1)
        ]])
        child.flush()

        child.lua([[
            local registry = require("agentic.session_registry")
            local session = registry.sessions[1]
            assert(session, "expected session 1 after new_session()")
            vim.api.nvim_set_current_win(session.widget.win_nrs.chat)
            local keys = vim.api.nvim_replace_termcodes(
                "<localLeader>D",
                true,
                false,
                true
            )
            vim.api.nvim_feedkeys(keys, "x", false)
        ]])
        child.flush()

        assert.equal(
            1,
            child.lua_get([[
                vim.tbl_count(require("agentic.session_registry").sessions)
            ]])
        )
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[1] == nil
        ]]))
        assert.is_true(child.lua_get([[
            require("agentic.session_registry").sessions[2] ~= nil
        ]]))
    end)
end)
