local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Add diagnostics to session", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd([[ edit tests/init.lua ]])
    end)

    after_each(function()
        child.stop()
    end)

    local function initialize_session_and_switch_to_buffer(bufnr)
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        child.lua([[ require("agentic").close() ]])
        child.flush()
        child.lua(("vim.api.nvim_set_current_buf(%d)"):format(bufnr))
    end

    local function get_session_diagnostics()
        return child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.diagnostics_list:get_diagnostics()
        ]])
    end

    it("Adds cursor-line diagnostics and opens diagnostics window", function()
        local bufnr = child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Test error on line 1",
                },
            })
            return bufnr
        ]])

        initialize_session_and_switch_to_buffer(bufnr)
        child.lua([[ vim.api.nvim_win_set_cursor(0, {1, 0}) ]])
        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        local diagnostics = get_session_diagnostics()
        assert.equal(1, #diagnostics)
        assert.equal("Test error on line 1", diagnostics[1].message)
        assert.equal(0, diagnostics[1].lnum)
        assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)

        local diagnostics_winid = child.lua([[
            local session = require("agentic.session_registry")
                .get_session_for_tab_page()
            return session.widget.win_nrs.diagnostics
        ]])
        assert.truthy(diagnostics_winid)
        assert.is_true(child.api.nvim_win_is_valid(diagnostics_winid))
    end)

    it("Adds all buffer diagnostics to session", function()
        local bufnr = child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "First error",
                },
                {
                    lnum = 5,
                    col = 10,
                    severity = vim.diagnostic.severity.WARN,
                    message = "Warning message",
                },
                {
                    lnum = 10,
                    col = 0,
                    severity = vim.diagnostic.severity.HINT,
                    message = "Hint for improvement",
                },
            })
            return bufnr
        ]])

        initialize_session_and_switch_to_buffer(bufnr)
        child.lua([[ require("agentic").add_buffer_diagnostics() ]])
        child.flush()

        local diagnostics = get_session_diagnostics()
        assert.equal(3, #diagnostics)
        assert.equal("First error", diagnostics[1].message)
        assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
        assert.equal("Warning message", diagnostics[2].message)
        assert.equal(vim.diagnostic.severity.WARN, diagnostics[2].severity)
        assert.equal("Hint for improvement", diagnostics[3].message)
        assert.equal(vim.diagnostic.severity.HINT, diagnostics[3].severity)
    end)

    it("Does not show widget when no diagnostics exist", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        child.lua([[ require("agentic").close() ]])
        child.flush()

        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        assert.equal(0, #get_session_diagnostics())

        local is_open = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.widget:is_open()
        ]])
        assert.is_false(is_open)
    end)
end)
