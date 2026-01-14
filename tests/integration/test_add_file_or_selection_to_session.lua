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

    it("Adds selected lines to code window", function()
        -- Select lines 28-29 using visual mode
        child.cmd("normal! 28GVj")

        -- Toggle widget while selection is active - should auto-add selection
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Get selections from code_selection
        local selections = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.code_selection:get_selections()
        ]])

        -- Read actual lines 28-29 from the test file
        local expected_lines = vim.fn.readfile("tests/init.lua", "", 29)
        expected_lines = { expected_lines[28], expected_lines[29] }

        assert.equal(1, #selections)
        assert.same(expected_lines, selections[1].lines)
        assert.equal(28, selections[1].start_line)
        assert.equal(29, selections[1].end_line)
    end)
end)
