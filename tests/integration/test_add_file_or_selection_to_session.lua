local FileSystem = require("agentic.utils.file_system")
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Add file or selection to session", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd([[ edit tests/init.lua ]])
    end)

    after_each(function()
        child.stop()
    end)

    it("Adds current file when open", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local files_winid = child.lua([[
            local session = require("agentic.session_registry")
                .get_session_for_tab_page()
            return session.widget.win_nrs.files
        ]])

        local files_list = child.lua([[
            local session = require("agentic.session_registry")
                .get_session_for_tab_page()
            return session.file_list:get_files()
        ]])

        assert.same({
            FileSystem.to_absolute_path("tests/init.lua"),
        }, files_list)
        assert.is_true(child.api.nvim_win_is_valid(files_winid))
    end)
end)
