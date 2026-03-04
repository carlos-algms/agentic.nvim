local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

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
        if on_change_spy and on_change_spy.revert then
            on_change_spy:revert()
        end

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
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
            vim.api.nvim_win_set_width(winid, 40)

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
                vim.api.nvim_buf_delete(test_bufnr, { force = true })
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
    end)

    describe("get_diagnostics_at_cursor", function()
        --- @type integer
        local test_bufnr
        --- @type integer
        local ns

        before_each(function()
            test_bufnr = vim.api.nvim_create_buf(false, true)
            ns = vim.api.nvim_create_namespace("test_diag_cursor")
            vim.api.nvim_set_current_buf(test_bufnr)
        end)

        after_each(function()
            vim.diagnostic.reset(ns, test_bufnr)
            if vim.api.nvim_buf_is_valid(test_bufnr) then
                vim.api.nvim_buf_delete(test_bufnr, { force = true })
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
    end)
end)
