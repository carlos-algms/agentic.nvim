local assert = require("tests.helpers.assert")
local DiagnosticsContext = require("agentic.ui.diagnostics_context")

describe("agentic.ui.DiagnosticsContext", function()
    it("formats diagnostics for prompt and chat summary", function()
        local diagnostics = {
            {
                bufnr = 1,
                lnum = 9,
                col = 4,
                severity = vim.diagnostic.severity.WARN,
                message = "Use <tag> & escape me",
                file_path = "lua/agentic/session_manager.lua",
            },
        }

        local result = DiagnosticsContext.format_diagnostics(diagnostics, 120)

        assert.equal(1, #result.prompt_entries)
        assert.equal(1, #result.summary_lines)
        assert.truthy(
            result.prompt_entries[1].text:find(
                "<severity>WARN</severity>",
                1,
                true
            )
        )
        assert.truthy(
            result.prompt_entries[1].text:find(
                "&lt;tag&gt; &amp; escape me",
                1,
                true
            )
        )
        assert.truthy(
            result.summary_lines[1]:find(
                "[WARN] lua/agentic/session_manager.lua:10:5",
                1,
                true
            )
        )
    end)

    it("uses unnamed buffer fallback and truncates summary", function()
        local diagnostics = {
            {
                bufnr = 1,
                lnum = 0,
                col = 0,
                severity = vim.diagnostic.severity.ERROR,
                message = "A very long diagnostic message that should be truncated",
                file_path = "",
            },
        }

        local result = DiagnosticsContext.format_diagnostics(diagnostics, 40)

        assert.truthy(
            result.prompt_entries[1].text:find(
                "<file>&lt;unnamed buffer&gt;</file>",
                1,
                true
            )
        )
        assert.truthy(
            result.summary_lines[1]:find(
                "[ERROR] <unnamed buffer>:1:1",
                1,
                true
            )
        )
        assert.equal("...", result.summary_lines[1]:sub(-3))
    end)
end)
