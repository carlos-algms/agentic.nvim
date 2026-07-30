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
            local session = require("agentic.session_registry").current()
            assert(session, "expected a session after new_session()")
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
            0,
            child.lua_get([[
                vim.tbl_count(require("agentic.session_registry").sessions)
            ]])
        )
    end)
end)
