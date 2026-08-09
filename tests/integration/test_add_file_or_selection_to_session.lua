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
            local session = require("agentic.session_registry").current()
            assert(session, "expected an existing session")
            return session.widget.win_nrs.files
        ]])

        local files_list = child.lua([[
            local session = require("agentic.session_registry").current()
            assert(session, "expected an existing session")
            return session.file_list:get_files()
        ]])

        assert.same({
            FileSystem.to_absolute_path("tests/init.lua"),
        }, files_list)
        assert.is_true(child.api.nvim_win_is_valid(files_winid))
    end)

    it("Adds selected lines to code window", function()
        child.cmd("normal! 28GVj")

        -- Toggling with a live selection auto-adds it
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        local code_winid = child.lua([[
            local session = require("agentic.session_registry").current()
            assert(session, "expected an existing session")
            return session.widget.win_nrs.code
        ]])

        local selections = child.lua([[
            local session = require("agentic.session_registry").current()
            assert(session, "expected an existing session")
            return session.code_selection:get_selections()
        ]])

        local expected_lines = vim.fn.readfile("tests/init.lua", "", 29)
        expected_lines = { expected_lines[28], expected_lines[29] }

        assert.equal(1, #selections)
        assert.same(expected_lines, selections[1].lines)
        assert.equal(28, selections[1].start_line)
        assert.equal(29, selections[1].end_line)
        assert.is_true(child.api.nvim_win_is_valid(code_winid))
    end)
end)
