local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local WidgetLayout = require("agentic.ui.widget_layout")
local WidgetRegistry = require("agentic.ui.widget_registry")

describe("agentic.ui.DiagnosticsList", function()
    local DiagnosticsList = require("agentic.ui.diagnostics_list")

    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.DiagnosticsList
    local diagnostics_list
    --- @type TestSpy
    local on_change_spy
    --- @type TestStub|nil
    local find_visible_win_stub
    --- @type agentic.ui.ChatWidget|nil
    local registered_widget
    --- @type table<integer, true>
    local baseline_tabs

    --- @return agentic.ui.DiagnosticsList.Diagnostic
    local function create_diagnostic(overrides)
        overrides = overrides or {}
        return {
            bufnr = overrides.bufnr or 1,
            lnum = overrides.lnum or 10,
            col = overrides.col or 5,
            severity = overrides.severity or vim.diagnostic.severity.ERROR,
            message = overrides.message or "Test error message",
            source = overrides.source or "test",
            code = overrides.code or "E001",
            file_path = overrides.file_path or "/path/to/test.lua",
        }
    end

    before_each(function()
        baseline_tabs = {}
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            baseline_tabs[tabpage] = true
        end
        find_visible_win_stub = nil
        registered_widget = nil

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, false, {
            relative = "editor",
            width = 120,
            height = 10,
            row = 0,
            col = 0,
        })
        on_change_spy = spy.new(function() end)

        diagnostics_list =
            DiagnosticsList:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        if find_visible_win_stub then
            find_visible_win_stub:revert()
        end
        if registered_widget then
            WidgetRegistry.unregister(registered_widget)
        end

        if on_change_spy and on_change_spy.revert then
            on_change_spy:revert()
        end

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end

        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
            if not baseline_tabs[tabpage] then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tabpage)
                    vim.cmd("tabclose!")
                end)
            end
        end
    end)

    describe("add and get_diagnostics", function()
        it("adds diagnostic and retrieves it", function()
            local diagnostic = create_diagnostic()

            local success = diagnostics_list:add(diagnostic)

            assert.is_true(success)

            local diagnostics = diagnostics_list:get_diagnostics()
            assert.equal(1, #diagnostics)
            assert.equal(diagnostic.message, diagnostics[1].message)
            assert.spy(on_change_spy).was.called(1)
        end)

        it("does not add nil diagnostic", function()
            local success = diagnostics_list:add(nil)

            assert.is_false(success)
            assert.is_true(diagnostics_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("does not add diagnostic without bufnr", function()
            local diagnostic = create_diagnostic()
            diagnostic.bufnr = nil

            local success = diagnostics_list:add(diagnostic)

            assert.is_false(success)
            assert.is_true(diagnostics_list:is_empty())
        end)

        it("does not add duplicate diagnostic", function()
            local diagnostic = create_diagnostic()

            diagnostics_list:add(diagnostic)
            diagnostics_list:add(diagnostic)

            local diagnostics = diagnostics_list:get_diagnostics()
            assert.equal(1, #diagnostics)
            assert.spy(on_change_spy).was.called(1)
        end)

        it("adds diagnostics with different locations", function()
            local diagnostic1 =
                create_diagnostic({ lnum = 10, message = "Error 1" })
            local diagnostic2 =
                create_diagnostic({ lnum = 20, message = "Error 2" })

            diagnostics_list:add(diagnostic1)
            diagnostics_list:add(diagnostic2)

            local diagnostics = diagnostics_list:get_diagnostics()
            assert.equal(2, #diagnostics)
            assert.spy(on_change_spy).was.called(2)
        end)

        it("adds diagnostics with same line but different messages", function()
            local diagnostic1 = create_diagnostic({ message = "Error 1" })
            local diagnostic2 = create_diagnostic({ message = "Error 2" })

            diagnostics_list:add(diagnostic1)
            diagnostics_list:add(diagnostic2)

            local diagnostics = diagnostics_list:get_diagnostics()
            assert.equal(2, #diagnostics)
        end)

        it("returns deep copy of diagnostics", function()
            local diagnostic = create_diagnostic()

            diagnostics_list:add(diagnostic)

            local diagnostics1 = diagnostics_list:get_diagnostics()
            local diagnostics2 = diagnostics_list:get_diagnostics()

            diagnostics1[1].message = "modified"

            assert.equal(diagnostic.message, diagnostics2[1].message)
        end)
    end)

    describe("add_many", function()
        it("adds multiple diagnostics at once", function()
            local diagnostics = {
                create_diagnostic({ lnum = 10 }),
                create_diagnostic({ lnum = 20 }),
                create_diagnostic({ lnum = 30 }),
            }

            local count = diagnostics_list:add_many(diagnostics)

            assert.equal(3, count)
            assert.equal(3, #diagnostics_list:get_diagnostics())
            assert.spy(on_change_spy).was.called(1)
        end)

        it("handles empty array", function()
            local count = diagnostics_list:add_many({})

            assert.equal(0, count)
            assert.is_true(diagnostics_list:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)

        it("counts only successfully added diagnostics", function()
            local diagnostics = {
                create_diagnostic({ lnum = 10 }),
                create_diagnostic({ lnum = 10 }), -- Duplicate
                create_diagnostic({ lnum = 20 }),
            }

            local count = diagnostics_list:add_many(diagnostics)

            assert.equal(2, count)
            assert.equal(2, #diagnostics_list:get_diagnostics())
        end)
    end)

    describe("is_empty", function()
        it("returns true when no diagnostics added", function()
            assert.is_true(diagnostics_list:is_empty())
        end)

        it("returns false when diagnostics exist", function()
            diagnostics_list:add(create_diagnostic())

            assert.is_false(diagnostics_list:is_empty())
        end)
    end)

    describe("clear", function()
        it("removes all diagnostics", function()
            diagnostics_list:add(create_diagnostic({ lnum = 10 }))
            diagnostics_list:add(create_diagnostic({ lnum = 20 }))
            assert.is_false(diagnostics_list:is_empty())

            diagnostics_list:clear()

            assert.is_true(diagnostics_list:is_empty())
            assert.spy(on_change_spy).was.called(3)
        end)

        it("clears buffer content", function()
            local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            diagnostics_list:add(create_diagnostic())
            local lines_after_add =
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_not.same(lines_before, lines_after_add)

            diagnostics_list:clear()

            local line_count = vim.api.nvim_buf_line_count(bufnr)
            assert.equal(1, line_count)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal("", lines[1])
        end)
    end)

    describe("remove_at", function()
        it("removes diagnostic at valid index", function()
            local diagnostic1 = create_diagnostic({ lnum = 10 })
            local diagnostic2 = create_diagnostic({ lnum = 20 })

            diagnostics_list:add(diagnostic1)
            diagnostics_list:add(diagnostic2)

            assert.equal(2, #diagnostics_list:get_diagnostics())

            diagnostics_list:remove_at(1)

            local diagnostics = diagnostics_list:get_diagnostics()
            assert.equal(1, #diagnostics)
            assert.equal(diagnostic2.message, diagnostics[1].message)
            assert.spy(on_change_spy).was.called(3)
        end)

        it("does not remove at invalid index (too small)", function()
            diagnostics_list:add(create_diagnostic({ lnum = 10 }))
            diagnostics_list:add(create_diagnostic({ lnum = 20 }))

            diagnostics_list:remove_at(0)

            assert.equal(2, #diagnostics_list:get_diagnostics())
            assert.spy(on_change_spy).was.called(2)
        end)

        it("does not remove at invalid index (too large)", function()
            diagnostics_list:add(create_diagnostic({ lnum = 10 }))
            diagnostics_list:add(create_diagnostic({ lnum = 20 }))

            diagnostics_list:remove_at(3)

            assert.equal(2, #diagnostics_list:get_diagnostics())
            assert.spy(on_change_spy).was.called(2)
        end)
    end)

    describe("buffer rendering", function()
        it("scopes lookup to the owning widget's diagnostics window", function()
            local captured_preferred
            local captured_tabpage
            --- @type any
            local widget = {
                tab_page_id = 1357,
                buf_nrs = { diagnostics = bufnr },
                win_nrs = { diagnostics = 2468 },
            }
            registered_widget = widget
            WidgetRegistry.register(widget)
            find_visible_win_stub = spy.stub(BufHelpers, "find_visible_win")
            find_visible_win_stub:invokes(function(_, preferred, tabpage)
                captured_preferred = preferred
                captured_tabpage = tabpage
                return nil
            end)

            diagnostics_list:add(create_diagnostic())

            assert.equal(2468, captured_preferred)
            assert.equal(1357, captured_tabpage)
        end)

        it("keeps default width when the registered owner is hidden", function()
            vim.cmd("tabnew")
            local owner_tab = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabprevious")

            --- @type any
            local widget = {
                tab_page_id = owner_tab,
                buf_nrs = { diagnostics = bufnr },
                win_nrs = {},
            }
            registered_widget = widget
            WidgetRegistry.register(widget)

            diagnostics_list:add(create_diagnostic({
                file_path = "/short.lua",
                message = string.rep("long diagnostic ", 20),
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local default_width =
                WidgetLayout.calculate_width(Config.windows.width)
            assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= default_width)
            assert.equal("...", lines[1]:sub(-3))
        end)

        it("renders diagnostics in buffer", function()
            local diagnostic = create_diagnostic({
                lnum = 10,
                col = 5,
                message = "Test error",
                file_path = "/path/to/test.lua",
            })

            diagnostics_list:add(diagnostic)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("Test error", 1, true))
            assert.truthy(lines[1]:find(Config.diagnostic_icons.error, 1, true))
        end)

        it("renders multiple diagnostics", function()
            diagnostics_list:add(
                create_diagnostic({ lnum = 10, message = "Error 1" })
            )
            diagnostics_list:add(
                create_diagnostic({ lnum = 20, message = "Error 2" })
            )

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(2, #lines)
            assert.truthy(lines[1]:find("Error 1", 1, true))
            assert.truthy(lines[2]:find("Error 2", 1, true))
        end)

        it("includes severity emoji", function()
            diagnostics_list:add(create_diagnostic({
                severity = vim.diagnostic.severity.WARN,
                message = "Warning message",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.truthy(lines[1]:find("Warning message", 1, true))
            assert.truthy(lines[1]:find(Config.diagnostic_icons.warn, 1, true))
        end)

        it("escapes newline in the middle of message", function()
            diagnostics_list:add(create_diagnostic({
                message = "Line one\nLine two",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("Line one\\nLine two", 1, true))
        end)

        it("escapes trailing newline in message", function()
            diagnostics_list:add(create_diagnostic({
                message = "Trailing newline\n",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("Trailing newline\\n", 1, true))
        end)

        it("includes file location", function()
            diagnostics_list:add(create_diagnostic({
                lnum = 10,
                col = 5,
                file_path = "/path/to/test.lua",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.truthy(lines[1]:find(":11:6", 1, true)) -- lnum+1, col+1
        end)

        it("truncates long lines with ellipsis to fit window width", function()
            vim.api.nvim_win_set_config(winid, { width = 40 })

            diagnostics_list:add(create_diagnostic({
                message = "A very long diagnostic message that should definitely be truncated to fit",
                file_path = "/short.lua",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.equal("...", lines[1]:sub(-3))
            assert.truthy(vim.fn.strdisplaywidth(lines[1]) <= 40)
        end)

        it("does not truncate when line fits within window width", function()
            diagnostics_list:add(create_diagnostic({
                message = "Short msg",
                file_path = "/short.lua",
            }))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("Short msg", 1, true))
            assert.is_nil(lines[1]:find("...", 1, true))
        end)

        it("updates buffer after removal", function()
            diagnostics_list:add(create_diagnostic({ lnum = 10 }))
            diagnostics_list:add(create_diagnostic({ lnum = 20 }))

            local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(2, #lines_before)

            diagnostics_list:remove_at(1)

            local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal(1, #lines_after)
        end)
    end)

    describe("to_prompt", function()
        it(
            "returns header, summary lines, prompt entries, and clears",
            function()
                diagnostics_list:add(
                    create_diagnostic({ lnum = 10, message = "Error 1" })
                )
                diagnostics_list:add(
                    create_diagnostic({ lnum = 20, message = "Error 2" })
                )

                local lines, prompt = diagnostics_list:to_prompt(120)

                assert.equal("\n- **Diagnostics**:", lines[1])
                assert.equal(3, #lines) -- header + one summary per diagnostic
                assert.truthy(lines[2]:find("Error 1", 1, true))
                assert.truthy(lines[3]:find("Error 2", 1, true))
                assert.equal(2, #prompt)
                assert.is_true(diagnostics_list:is_empty())
            end
        )
    end)

    describe("get_buffer_diagnostics", function()
        --- @type integer
        local test_bufnr
        --- @type integer
        local ns

        before_each(function()
            test_bufnr = vim.api.nvim_create_buf(false, true)
            ns = vim.api.nvim_create_namespace("test_diag_buf")
        end)

        after_each(function()
            vim.diagnostic.reset(ns, test_bufnr)
            if vim.api.nvim_buf_is_valid(test_bufnr) then
                pcall(vim.api.nvim_buf_delete, test_bufnr, { force = true })
            end
        end)

        it("returns empty array when no diagnostics", function()
            local diagnostics =
                DiagnosticsList.get_buffer_diagnostics(test_bufnr)

            assert.equal(0, #diagnostics)
        end)

        it("converts vim diagnostics to internal format", function()
            vim.api.nvim_buf_set_name(test_bufnr, "/test/file.lua")

            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 5,
                    col = 10,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Test error",
                    source = "test_source",
                    code = "E123",
                },
            })

            local diagnostics =
                DiagnosticsList.get_buffer_diagnostics(test_bufnr)

            assert.equal(1, #diagnostics)
            assert.equal(5, diagnostics[1].lnum)
            assert.equal(10, diagnostics[1].col)
            assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
            assert.equal("Test error", diagnostics[1].message)
            assert.equal("test_source", diagnostics[1].source)
            assert.equal("E123", diagnostics[1].code)
            assert.equal("/test/file.lua", diagnostics[1].file_path)
        end)

        it("defaults to ERROR severity when not specified", function()
            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    message = "Test message",
                },
            })

            local diagnostics =
                DiagnosticsList.get_buffer_diagnostics(test_bufnr)

            assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
        end)

        it("stamps file_path on every returned diagnostic", function()
            vim.api.nvim_buf_set_name(test_bufnr, "/test/stamped.lua")

            vim.diagnostic.set(ns, test_bufnr, {
                { lnum = 0, col = 0, message = "first" },
                { lnum = 1, col = 0, message = "second" },
                { lnum = 2, col = 0, message = "third" },
            })

            local diagnostics =
                DiagnosticsList.get_buffer_diagnostics(test_bufnr)

            assert.equal(3, #diagnostics)
            for _, d in ipairs(diagnostics) do
                assert.equal("/test/stamped.lua", d.file_path)
            end
        end)
    end)

    describe("get_diagnostics_at_cursor", function()
        --- @type integer
        local test_bufnr
        --- @type integer
        local ns

        --- Handle set, not a count: the cross-tab cases move the current tab
        --- around, so a count-based `tabclose!` loop can shut a baseline tab
        --- while a test-created one survives.
        --- @type table<integer, true>
        local base_tabs

        before_each(function()
            base_tabs = {}
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                base_tabs[tab] = true
            end
            test_bufnr = vim.api.nvim_create_buf(false, true)
            ns = vim.api.nvim_create_namespace("test_diag_cursor")
            vim.api.nvim_set_current_buf(test_bufnr)
        end)

        after_each(function()
            -- Closes only tabpages absent from the baseline, so a red assertion
            -- in a cross-tab case cannot leak one into every later test file.
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                if
                    not base_tabs[tab] and vim.api.nvim_tabpage_is_valid(tab)
                then
                    pcall(function()
                        vim.api.nvim_set_current_tabpage(tab)
                        vim.cmd("tabclose!")
                    end)
                end
            end

            vim.diagnostic.reset(ns, test_bufnr)
            if vim.api.nvim_buf_is_valid(test_bufnr) then
                pcall(vim.api.nvim_buf_delete, test_bufnr, { force = true })
            end
        end)

        it("returns diagnostics at cursor line", function()
            vim.api.nvim_buf_set_lines(
                test_bufnr,
                0,
                -1,
                false,
                { "line1", "line2", "line3" }
            )

            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 1,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Error on line 2",
                },
                {
                    lnum = 2,
                    col = 0,
                    severity = vim.diagnostic.severity.WARN,
                    message = "Warning on line 3",
                },
            })

            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            local diagnostics =
                DiagnosticsList.get_diagnostics_at_cursor(test_bufnr)

            assert.equal(1, #diagnostics)
            assert.equal("Error on line 2", diagnostics[1].message)
        end)

        it("returns empty array when no diagnostics at cursor", function()
            vim.api.nvim_buf_set_lines(
                test_bufnr,
                0,
                -1,
                false,
                { "line1", "line2" }
            )

            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Error on line 1",
                },
            })

            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            local diagnostics =
                DiagnosticsList.get_diagnostics_at_cursor(test_bufnr)

            assert.equal(0, #diagnostics)
        end)

        it("includes a multi-line range spanning the cursor", function()
            vim.api.nvim_buf_set_lines(
                test_bufnr,
                0,
                -1,
                false,
                { "line1", "line2", "line3", "line4" }
            )

            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 0,
                    end_lnum = 2,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Spans lines 1-3",
                },
                {
                    lnum = 3,
                    col = 0,
                    severity = vim.diagnostic.severity.WARN,
                    message = "Only line 4",
                },
            })

            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            local diagnostics =
                DiagnosticsList.get_diagnostics_at_cursor(test_bufnr)

            assert.equal(1, #diagnostics)
            assert.equal("Spans lines 1-3", diagnostics[1].message)
        end)

        it("returns an empty array when the buffer is in no window", function()
            local hidden_bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(hidden_bufnr, 0, -1, false, { "line1" })

            vim.diagnostic.set(ns, hidden_bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Error on line 1",
                },
            })

            local diagnostics =
                DiagnosticsList.get_diagnostics_at_cursor(hidden_bufnr)

            assert.equal(0, #diagnostics)

            vim.diagnostic.reset(ns, hidden_bufnr)
            pcall(vim.api.nvim_buf_delete, hidden_bufnr, { force = true })
        end)

        it(
            "returns diagnostics when the buffer's only window is in another tab",
            function()
                vim.api.nvim_buf_set_lines(
                    test_bufnr,
                    0,
                    -1,
                    false,
                    { "line1", "line2", "line3" }
                )

                vim.diagnostic.set(ns, test_bufnr, {
                    {
                        lnum = 1,
                        col = 0,
                        severity = vim.diagnostic.severity.ERROR,
                        message = "Error on line 2",
                    },
                })

                -- Park the buffer's only window in its own tab, then leave.
                -- `before_each` also put it in the starting window; that copy
                -- must go or the lookup legitimately finds it here.
                vim.cmd("tabnew")
                local other_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_buf(other_win, test_bufnr)
                vim.api.nvim_win_set_cursor(other_win, { 2, 0 })
                vim.cmd("tabprevious")
                vim.api.nvim_win_set_buf(
                    vim.api.nvim_get_current_win(),
                    vim.api.nvim_create_buf(false, true)
                )

                -- Defect: the current-tab-only lookup found no window here and
                -- silently yielded nothing.
                local diagnostics =
                    DiagnosticsList.get_diagnostics_at_cursor(test_bufnr)

                assert.equal(1, #diagnostics)
                assert.equal("Error on line 2", diagnostics[1].message)
            end
        )

        it("prefers the current window's cursor over another tab's", function()
            -- Both tabs hold the buffer at DIFFERENT lines; dropping either copy
            -- collapses to the single-match path and stops exercising the
            -- ambiguity. Without a preferred window `win_findbuf` order decides,
            -- so the other tab's line 3 wins and the user gets a diagnostic they
            -- are not sitting on.
            vim.api.nvim_buf_set_lines(
                test_bufnr,
                0,
                -1,
                false,
                { "line1", "line2", "line3" }
            )

            vim.diagnostic.set(ns, test_bufnr, {
                {
                    lnum = 1,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Error on line 2",
                },
                {
                    lnum = 2,
                    col = 0,
                    severity = vim.diagnostic.severity.WARN,
                    message = "Warning on line 3",
                },
            })

            -- `win_findbuf` returns tabpage order regardless of the current tab,
            -- so the earlier tab's copy wins an unpreferred lookup. Park the
            -- decoy FIRST and stay in the later tab.
            local other_win = vim.api.nvim_get_current_win()
            assert.equal(test_bufnr, vim.api.nvim_win_get_buf(other_win))
            vim.api.nvim_win_set_cursor(other_win, { 3, 0 })

            vim.cmd("tabnew")
            local current_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(current_win, test_bufnr)
            vim.api.nvim_win_set_cursor(current_win, { 2, 0 })

            local diagnostics =
                DiagnosticsList.get_diagnostics_at_cursor(test_bufnr)

            assert.equal(1, #diagnostics)
            assert.equal("Error on line 2", diagnostics[1].message)
        end)
    end)

    describe("visual-mode delete", function()
        --- Enters the diagnostics window, selects `from`..`to` linewise and presses `d`.
        --- `V` and the motion go in ONE `normal` sequence: splitting them across
        --- `nvim_win_set_cursor` loses the visual anchor, so only one line is
        --- selected and the multi-line loop is never exercised.
        --- @param from integer
        --- @param to integer
        local function visual_delete(from, to)
            vim.api.nvim_set_current_win(winid)
            vim.api.nvim_win_set_cursor(winid, { from, 0 })
            -- `normal` (not `normal!`) so the buffer-local `v`-mode `d` mapping runs.
            vim.cmd(string.format("normal V%dGd", to))
        end

        --- @param count integer
        local function seed(count)
            for i = 1, count do
                diagnostics_list:add(create_diagnostic({
                    bufnr = bufnr,
                    lnum = i,
                    message = "diag " .. i,
                }))
            end
        end

        --- @return string[]
        local function messages()
            local result = {}
            for _, d in ipairs(diagnostics_list:get_diagnostics()) do
                result[#result + 1] = d.message
            end
            return result
        end

        it("removes exactly the three selected entries", function()
            seed(5)

            visual_delete(2, 4)

            assert.same({ "diag 1", "diag 5" }, messages())
        end)

        it("removes the same set for a backward selection", function()
            seed(5)

            visual_delete(4, 2)

            assert.same({ "diag 1", "diag 5" }, messages())
        end)

        it("ignores a selection reaching past the end of the list", function()
            seed(2)
            -- Blank padding after the rendered diagnostics, so the selection can
            -- extend past the last entry.
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 2, -1, false, { "", "", "" })
            vim.bo[bufnr].modifiable = false

            visual_delete(2, 5)

            assert.same({ "diag 1" }, messages())
        end)
    end)
end)
