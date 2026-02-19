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

    it("Adds diagnostics at cursor to diagnostics window", function()
        -- Set up a diagnostic on line 1 of the current buffer
        local bufnr = child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,  -- Line 1 (0-indexed)
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Test error on line 1",
                },
            })
            return bufnr
        ]])

        -- Ensure the session exists by opening the widget first
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Close it so we can add diagnostics properly
        child.lua([[ require("agentic").close() ]])
        child.flush()

        -- Now set the buffer again and add diagnostics
        -- This simulates the user being in their file buffer
        child.lua(([[
            vim.api.nvim_set_current_buf(%d)
            vim.api.nvim_win_set_cursor(0, {1, 0})
        ]]):format(bufnr))

        -- Add diagnostics at cursor (cursor should be on line 1)
        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        -- Get diagnostics from diagnostics_list
        local diagnostics = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.diagnostics_list:get_diagnostics()
        ]])

        assert.equal(1, #diagnostics)
        assert.equal("Test error on line 1", diagnostics[1].message)
        assert.equal(0, diagnostics[1].lnum)
        assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)

        -- Clean up
        child.lua(([[
            vim.diagnostic.reset(vim.api.nvim_create_namespace("test_diagnostics"), %d)
        ]]):format(bufnr))
    end)

    it("Adds all buffer diagnostics to session", function()
        -- Set up multiple diagnostics on the current buffer
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

        -- Ensure the session exists by opening the widget first
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Close it so we can add diagnostics properly
        child.lua([[ require("agentic").close() ]])
        child.flush()

        -- Now set the buffer again and add diagnostics
        child.lua(([[
            vim.api.nvim_set_current_buf(%d)
        ]]):format(bufnr))

        -- Add all buffer diagnostics
        child.lua([[ require("agentic").add_buffer_diagnostics() ]])
        child.flush()

        -- Get diagnostics from diagnostics_list
        local diagnostics = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.diagnostics_list:get_diagnostics()
        ]])

        assert.equal(3, #diagnostics)

        -- Verify first diagnostic
        assert.equal("First error", diagnostics[1].message)
        assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)

        -- Verify second diagnostic
        assert.equal("Warning message", diagnostics[2].message)
        assert.equal(vim.diagnostic.severity.WARN, diagnostics[2].severity)

        -- Verify third diagnostic
        assert.equal("Hint for improvement", diagnostics[3].message)
        assert.equal(vim.diagnostic.severity.HINT, diagnostics[3].severity)

        -- Clean up
        child.lua(([[
            vim.diagnostic.reset(vim.api.nvim_create_namespace("test_diagnostics"), %d)
        ]]):format(bufnr))
    end)

    it("Shows diagnostics window when diagnostics are added", function()
        -- Set up a diagnostic on the current buffer
        local bufnr = child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Test error",
                },
            })
            return bufnr
        ]])

        -- Ensure the session exists by opening the widget first
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Close it so we can add diagnostics properly
        child.lua([[ require("agentic").close() ]])
        child.flush()

        -- Now set the buffer again and add diagnostics
        child.lua(([[
            vim.api.nvim_set_current_buf(%d)
        ]]):format(bufnr))

        -- Add diagnostics
        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        -- Check if diagnostics window is valid
        local diagnostics_winid = child.lua([[
            local session = require("agentic.session_registry")
                .get_session_for_tab_page()
            return session.widget.win_nrs.diagnostics
        ]])

        local diagnostics_count = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return #session.diagnostics_list:get_diagnostics()
        ]])

        assert.is_true(diagnostics_count > 0)
        assert.truthy(diagnostics_winid)
        assert.is_true(child.api.nvim_win_is_valid(diagnostics_winid))

        -- Clean up
        child.lua(([[
            vim.diagnostic.reset(vim.api.nvim_create_namespace("test_diagnostics"), %d)
        ]]):format(bufnr))
    end)

    it("Does not show widget when no diagnostics exist", function()
        -- Open widget first
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        -- Close widget
        child.lua([[ require("agentic").close() ]])
        child.flush()

        -- Try to add diagnostics when none exist
        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        -- Widget was opened then closed above; adding diagnostics with no
        -- entries should not reopen the diagnostics window.
        local diagnostics_list = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.diagnostics_list:get_diagnostics()
        ]])

        -- No diagnostics should have been added
        assert.equal(0, #diagnostics_list)

        local is_open = child.lua([[
            local session = require("agentic.session_registry").get_session_for_tab_page()
            return session.widget:is_open()
        ]])
        assert.is_false(is_open)
    end)
end)
